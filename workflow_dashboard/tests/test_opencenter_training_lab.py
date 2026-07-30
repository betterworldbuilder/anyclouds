#!/usr/bin/env python3
"""Concurrent dry run for the role-aware OpenCenter Quick Start sandbox."""

import csv
import io
import os
import shutil
import tempfile
import threading
import unittest
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


LAB_ROOT = tempfile.mkdtemp(prefix="opencenter-five-user-dry-run-")
os.environ["OPENCENTER_TRAINING_LAB_ROOT"] = LAB_ROOT
os.environ["OPENCENTER_TRAINING_MAX_COMMANDS"] = "8"
os.environ["OPENCENTER_TRUST_SSO_HEADERS"] = "1"
os.environ["OPENCENTER_TRAINING_DEFAULT_COHORT"] = "Five User Dry Run"
os.environ["FLASK_SECRET_KEY"] = "test-only-opencenter-lab-secret"
os.environ["WORKFLOW_DASHBOARD_DISABLE_SELF_RESTART"] = "1"

from workflow_dashboard.app import app  # noqa: E402


class OpenCenterFiveUserDryRun(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        app.config.update(TESTING=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(LAB_ROOT, ignore_errors=True)

    def exercise_user(self, number, role, barrier):
        client = app.test_client()
        self.assertEqual(client.get("/api/opencenter/lab-session").status_code, 401)

        name = f"{role} {number}"
        login = client.post(
            "/api/opencenter/training-login",
            json={"name": name, "role": role},
        )
        self.assertEqual(login.status_code, 200, login.get_data(as_text=True))
        self.assertEqual(login.get_json()["role"], role)

        info_response = client.get("/api/opencenter/lab-session")
        self.assertEqual(info_response.status_code, 200)
        info = info_response.get_json()
        self.assertEqual(info["learner"], name)
        self.assertEqual(info["role"], role)
        headers = {"X-OpenCenter-Lab-CSRF": info["csrf"]}
        org = info["suggested_org"]
        cluster = info["suggested_cluster"]
        unique_secret = f"five-user-secret-{number}"
        config_path = (
            f"$HOME/.config/opencenter/clusters/blueprints/"
            f"{org}/{cluster}/{cluster}-config.yaml"
        )

        saved = client.post(
            "/api/openrc/save-config",
            headers=headers,
            json={
                "path": config_path,
                "content": (
                    f"name: {cluster}\n"
                    f"learner: {number}\n"
                    f"password: {unique_secret}\n"
                ),
            },
        )
        self.assertEqual(saved.status_code, 200, saved.get_data(as_text=True))

        read_back = client.get(
            "/api/openrc/read-config",
            query_string={"path": config_path},
            headers=headers,
        )
        self.assertEqual(read_back.status_code, 200)
        self.assertIn(unique_secret, read_back.get_json()["content"])

        barrier.wait(timeout=15)
        command = client.post(
            "/api/stream/run-cmd",
            headers=headers,
            json={"command_id": "ocqs-cmd-pre-git", "cmd": "git --version"},
            buffered=True,
        )
        self.assertEqual(command.status_code, 200, command.get_data(as_text=True))
        command_text = command.get_data(as_text=True)
        self.assertIn("git version", command_text)
        self.assertIn("[EXIT 0]", command_text)

        published = client.post(
            "/api/opencenter/lab-result",
            headers=headers,
            json={
                "org": org,
                "cluster": cluster,
                "provider": "openstack",
                "completed_checks": number + 8,
                "role": "Instructor",
                "readiness": {"deployment_verified": number % 2 == 0},
            },
        )
        self.assertEqual(published.status_code, 200, published.get_data(as_text=True))
        self.assertEqual(published.get_json()["result"]["role"], role)

        feedback = client.post(
            "/api/opencenter/lab-feedback",
            headers=headers,
            json={
                "kind": "not_working" if number == 4 else "improvement",
                "stage": f"Stage {number + 1}",
                "message": f"Dry-run feedback from learner {number}.",
            },
        )
        self.assertEqual(feedback.status_code, 200, feedback.get_data(as_text=True))

        exported = client.get(
            "/api/opencenter/export-bundle",
            query_string={"org": org, "cluster": cluster},
            headers=headers,
        )
        self.assertEqual(exported.status_code, 200)
        with zipfile.ZipFile(io.BytesIO(exported.data)) as bundle:
            combined = b"\n".join(bundle.read(name) for name in bundle.namelist())
        self.assertNotIn(unique_secret.encode(), combined)
        self.assertIn(b"REDACTED_FOR_TRAINING_EXPORT", combined)

        with client.session_transaction() as learner_session:
            home = (
                Path(LAB_ROOT)
                / learner_session["opencenter_lab_identity"]
                / learner_session["opencenter_lab_id"]
                / "home"
            )
        return {
            "client": client,
            "headers": headers,
            "info": info,
            "home": home,
            "config_path": config_path,
            "role": role,
        }

    def test_five_simultaneous_role_sessions_and_cohort_review(self):
        barrier = threading.Barrier(5)
        roles = ["Instructor", "Student", "Student", "Student", "Student"]
        with ThreadPoolExecutor(max_workers=5) as executor:
            futures = [
                executor.submit(self.exercise_user, number, role, barrier)
                for number, role in enumerate(roles)
            ]
            users = [future.result(timeout=90) for future in futures]

        self.assertEqual(len({user["info"]["lab_id"] for user in users}), 5)
        self.assertEqual(len({str(user["home"]) for user in users}), 5)
        for user in users:
            self.assertTrue(user["home"].is_dir())

        other_config = (
            users[1]["home"]
            / ".config"
            / "opencenter"
            / "clusters"
            / "blueprints"
            / users[1]["info"]["suggested_org"]
            / users[1]["info"]["suggested_cluster"]
            / f"{users[1]['info']['suggested_cluster']}-config.yaml"
        )
        cross_read = users[0]["client"].get(
            "/api/openrc/read-config",
            query_string={"path": str(other_config)},
            headers=users[0]["headers"],
        )
        self.assertEqual(cross_read.status_code, 400)

        for user in users:
            review = user["client"].get(
                "/api/opencenter/cohort-review",
                headers=user["headers"],
            )
            self.assertEqual(review.status_code, 200)
            data = review.get_json()
            self.assertEqual(len(data["results"]), 5)
            self.assertEqual(len(data["feedback"]), 5)
            self.assertEqual(data["viewer_role"], user["role"])
            self.assertNotIn("five-user-secret", str(data))

        sso_override = users[1]["client"].get(
            "/api/opencenter/lab-session",
            headers={
                "X-Forwarded-User": "sso.instructor@example.com",
                "X-Auth-Request-Groups": "students,instructor",
                "X-Training-Cohort": "Five User Dry Run",
            },
        )
        self.assertEqual(sso_override.status_code, 200)
        self.assertTrue(sso_override.get_json()["sso_authenticated"])
        self.assertEqual(sso_override.get_json()["role"], "Instructor")
        self.assertEqual(sso_override.get_json()["learner"], "sso.instructor@example.com")


class OpenCenterCohortQandA(unittest.TestCase):
    """Q&A feedback: students ask, only instructors answer, everyone sees it."""

    @classmethod
    def setUpClass(cls):
        app.config.update(TESTING=True)

    def _session(self, name, role):
        client = app.test_client()
        client.post(
            "/api/opencenter/training-login", json={"name": name, "role": role}
        )
        token = client.get("/api/opencenter/lab-session").get_json()["csrf"]
        return client, {"X-OpenCenter-Lab-CSRF": token}

    def _ask(self, client, headers, message):
        response = client.post(
            "/api/opencenter/lab-feedback",
            json={"kind": "question", "stage": "Stage 3", "message": message},
            headers=headers,
        )
        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))
        return response.get_json()["feedback"]["id"]

    def test_question_kind_is_accepted_alongside_the_original_two(self):
        client, headers = self._session("Kind Check", "Student")
        for kind in ("improvement", "not_working", "question"):
            response = client.post(
                "/api/opencenter/lab-feedback",
                json={"kind": kind, "stage": "S", "message": "a valid message"},
                headers=headers,
            )
            self.assertEqual(response.status_code, 200, kind)
        rejected = client.post(
            "/api/opencenter/lab-feedback",
            json={"kind": "bogus", "stage": "S", "message": "a valid message"},
            headers=headers,
        )
        self.assertEqual(rejected.status_code, 400)

    def test_only_an_instructor_can_answer_a_question(self):
        student, student_headers = self._session("Asker", "Student")
        question_id = self._ask(student, student_headers, "How do I rotate the key?")

        self_answer = student.post(
            "/api/opencenter/lab-feedback-answer",
            json={"id": question_id, "answer": "guessing"},
            headers=student_headers,
        )
        self.assertEqual(self_answer.status_code, 403)

        instructor, instructor_headers = self._session("Coop", "Instructor")
        answered = instructor.post(
            "/api/opencenter/lab-feedback-answer",
            json={"id": question_id, "answer": "Run sops updatekeys."},
            headers=instructor_headers,
        )
        self.assertEqual(answered.status_code, 200, answered.get_data(as_text=True))
        self.assertEqual(answered.get_json()["feedback"]["answered_by"], "Coop")

    def test_answer_endpoint_validates_id_and_length_and_requires_csrf(self):
        instructor, headers = self._session("Validator", "Instructor")
        cases = [
            ({"id": "not-hex", "answer": "fine"}, 400),
            ({"id": "0" * 32, "answer": "fine"}, 404),
        ]
        for payload, expected in cases:
            response = instructor.post(
                "/api/opencenter/lab-feedback-answer", json=payload, headers=headers
            )
            self.assertEqual(response.status_code, expected, payload)

        student, student_headers = self._session("Short", "Student")
        question_id = self._ask(student, student_headers, "a real question here")
        too_short = instructor.post(
            "/api/opencenter/lab-feedback-answer",
            json={"id": question_id, "answer": "x"},
            headers=headers,
        )
        self.assertEqual(too_short.status_code, 400)

        # the new route must sit behind the same lab CSRF guard as the rest
        no_token = instructor.post(
            "/api/opencenter/lab-feedback-answer",
            json={"id": question_id, "answer": "no token supplied"},
        )
        self.assertEqual(no_token.status_code, 403)

    def test_instructor_review_shows_every_learner_and_the_posted_answers(self):
        asked = {}
        for name in ("Zain", "Rosa"):
            client, headers = self._session(name, "Student")
            asked[name] = self._ask(client, headers, f"{name} asks about SOPS")

        instructor, instructor_headers = self._session("Reviewer", "Instructor")
        for name, question_id in asked.items():
            self.assertEqual(
                instructor.post(
                    "/api/opencenter/lab-feedback-answer",
                    json={"id": question_id, "answer": f"Answer for {name}."},
                    headers=instructor_headers,
                ).status_code,
                200,
            )

        review = instructor.get(
            "/api/opencenter/cohort-review", headers=instructor_headers
        ).get_json()
        self.assertEqual(review["viewer_role"], "Instructor")
        by_id = {item["id"]: item for item in review["feedback"]}
        for name, question_id in asked.items():
            self.assertIn(question_id, by_id, f"{name}'s question is missing")
            self.assertEqual(by_id[question_id]["author"], name)
            self.assertEqual(by_id[question_id]["answer"], f"Answer for {name}.")

        # and the learner who asked can read the answer back
        student, student_headers = self._session("Zain", "Student")
        student_view = student.get(
            "/api/opencenter/cohort-review", headers=student_headers
        ).get_json()
        seen = {item["id"]: item for item in student_view["feedback"]}
        self.assertEqual(seen[asked["Zain"]]["answer"], "Answer for Zain.")


class OpenCenterTrainingLogExport(unittest.TestCase):
    """Training log rows and the CSV export learners hand to an instructor."""

    @classmethod
    def setUpClass(cls):
        app.config.update(TESTING=True)

    def _session(self, name, role):
        client = app.test_client()
        client.post(
            "/api/opencenter/training-login", json={"name": name, "role": role}
        )
        token = client.get("/api/opencenter/lab-session").get_json()["csrf"]
        return client, {"X-OpenCenter-Lab-CSRF": token}, token

    def test_log_counts_results_feedback_and_open_questions(self):
        student, headers, _ = self._session("Logger", "Student")
        question = student.post(
            "/api/opencenter/lab-feedback",
            json={"kind": "question", "stage": "Stage 3", "message": "a real question"},
            headers=headers,
        ).get_json()["feedback"]["id"]
        student.post(
            "/api/opencenter/lab-result",
            json={"org": "acme", "cluster": "lab1", "completed_checks": 7},
            headers=headers,
        )

        log = student.get("/api/opencenter/training-log", headers=headers).get_json()
        self.assertTrue(log["ok"])
        self.assertGreaterEqual(log["counts"]["results"], 1)
        self.assertGreaterEqual(log["counts"]["questions"], 1)
        self.assertGreaterEqual(log["counts"]["unanswered"], 1)
        self.assertEqual(
            {row["record_type"] for row in log["rows"]}, {"result", "feedback"}
        )

        instructor, instructor_headers, _ = self._session("Marker", "Instructor")
        instructor.post(
            "/api/opencenter/lab-feedback-answer",
            json={"id": question, "answer": "Answered for the log."},
            headers=instructor_headers,
        )
        # Other tests in this module share the cohort store, so assert on this
        # question rather than the cohort-wide unanswered count.
        after = instructor.get(
            "/api/opencenter/training-log", headers=instructor_headers
        ).get_json()
        answered = [
            row
            for row in after["rows"]
            if row.get("answer") == "Answered for the log."
        ]
        self.assertEqual(len(answered), 1)
        self.assertEqual(answered[0]["answered_by"], "Marker")
        self.assertLess(after["counts"]["unanswered"], log["counts"]["unanswered"])

    def test_csv_export_neutralizes_formulas_and_redacts_credentials(self):
        student, headers, token = self._session("Exporter", "Student")
        student.post(
            "/api/opencenter/lab-feedback",
            json={
                "kind": "not_working",
                "stage": "Stage 3",
                "message": "=cmd|calc!A1 and password: hunter2 plus token=abcd1234",
            },
            headers=headers,
        )

        response = student.get(f"/api/opencenter/training-log.csv?lab_token={token}")
        self.assertEqual(response.status_code, 200)
        self.assertIn("text/csv", response.headers["Content-Type"])
        self.assertIn("attachment", response.headers["Content-Disposition"])

        body = response.get_data(as_text=True)
        cells = [
            cell
            for row in csv.reader(io.StringIO(body))
            for cell in row
            if "cmd|calc" in cell
        ]
        self.assertTrue(cells, "the message should appear in the export")
        self.assertTrue(
            cells[0].startswith("'="),
            f"spreadsheet formula was not neutralized: {cells[0]!r}",
        )
        self.assertNotIn("hunter2", body)
        self.assertNotIn("abcd1234", body)
        self.assertIn("[REDACTED]", body)

    def test_both_log_routes_require_the_lab_token(self):
        anonymous = app.test_client()
        self.assertIn(
            anonymous.get("/api/opencenter/training-log").status_code, (401, 403)
        )
        student, headers, _ = self._session("Guarded", "Student")
        self.assertEqual(
            student.get("/api/opencenter/training-log.csv").status_code, 403
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)

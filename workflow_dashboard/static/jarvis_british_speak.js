/**
 * Shared Jarvis TTS: original British male/female browser voices.
 * Uses #enable_jarvis_voice / #jarvis_voice_gender when present (image migrator),
 * else localStorage mig_jarvis_voice / mig_jarvis_gender (default on, male).
 * Call jarvisAnnounce(text) or jarvisSpeakBritish(text) from any stage.
 */
(function () {
  'use strict';

  function voiceEnabled() {
    var el = document.getElementById('enable_jarvis_voice');
    if (el) return !!el.checked;
    return localStorage.getItem('mig_jarvis_voice') !== 'false';
  }

  function voiceGender() {
    var g = document.getElementById('jarvis_voice_gender');
    if (g && g.value) return g.value;
    var ls = localStorage.getItem('mig_jarvis_gender');
    if (ls === 'female' || ls === 'male') return ls;
    return 'female';
  }

  // Known British female voice names (Chrome, Edge, Windows, macOS, iOS)
  var BRIT_FEMALE = ['Google UK English Female', 'Libby', 'Mia', 'Sonia', 'Hazel', 'Serena',
    'Fiona', 'Susan', 'Amy', 'Emma', 'Kate', 'Martha', 'Stephanie'];
  // Known British male voice names
  var BRIT_MALE   = ['Google UK English Male', 'Daniel', 'George', 'Arthur', 'Ryan', 'Oliver'];

  function pickBritishVoice(voices, gender) {
    var names = gender === 'female' ? BRIT_FEMALE : BRIT_MALE;
    // 1. Exact name match against known list
    var preferred = null;
    for (var i = 0; i < names.length && !preferred; i++) {
      preferred = voices.find(function (v) { return v.name.includes(names[i]); });
    }
    // 2. Any en-GB voice (gender-matched list exhausted)
    if (!preferred) preferred = voices.find(function (v) { return v.lang === 'en-GB' || v.lang === 'en_GB'; });
    // 3. Any English voice
    if (!preferred) preferred = voices.find(function (v) { return v.lang && v.lang.startsWith('en'); });
    return preferred || voices[0];
  }

  function speak(text) {
    if (!text) return;
    text = String(text || '').trim();
    if (!text) return;

    window.__jarvisErrorReviewState = window.__jarvisErrorReviewState || { announced: false };
    if (/\b(starting|started|initializing|initiated|launching)\b/i.test(text)) {
      window.__jarvisErrorReviewState.announced = false;
    }
    if (/\b(error|failed|failure|fatal|exception|traceback|operator intervention|required|review the execution log|check the log|network error|process exited with code [1-9])\b/i.test(text)) {
      if (window.__jarvisErrorReviewState.announced) return;
      window.__jarvisErrorReviewState.announced = true;
      text = 'Migration error detected. Review the execution log.';
    }

    if (!voiceEnabled()) return;
    if (!('speechSynthesis' in window)) return;

    window.speechSynthesis.cancel();
    var msg = new SpeechSynthesisUtterance(text);
    var gender = voiceGender();

    function setVoiceAndSpeak() {
      var voices = window.speechSynthesis.getVoices();
      var preferred = pickBritishVoice(voices, gender);
      if (preferred) msg.voice = preferred;
      msg.rate = 1.0;
      msg.pitch = gender === 'female' ? 1.15 : 0.95;
      window.speechSynthesis.speak(msg);
    }

    if (window.speechSynthesis.getVoices().length === 0) {
      window.speechSynthesis.addEventListener('voiceschanged', setVoiceAndSpeak, { once: true });
    } else {
      setVoiceAndSpeak();
    }
  }

  window.jarvisSpeakBritish = speak;
  window.jarvisAnnounce = speak;
  window.jarvisResetErrorReviewAlert = function () {
    window.__jarvisErrorReviewState = { announced: false };
  };
  // Interrupts whatever is speaking right now. Distinct from the enable/
  // disable checkbox, which only affects announcements made after it's
  // toggled - this stops the CURRENT utterance immediately.
  window.jarvisStop = function () {
    if ('speechSynthesis' in window) window.speechSynthesis.cancel();
  };
})();

#!/bin/bash
curl -s -X POST http://127.0.0.1:5001/api/topology/rollback \
  -H "Content-Type: application/json" \
  -d '{"openrc_content":"","openrc_file":"1openrc (ok).sh"}'
echo

"""The corrected version of vulnerable-app/app.py.

Each change addresses a specific finding from the bandit scan.
"""
import ast
import os
import shlex
import sqlite3
import subprocess

from flask import Flask, jsonify, request

app = Flask(__name__)

# B105 fixed: read credentials from the environment, never from source.
API_TOKEN = os.environ.get("API_TOKEN")
DB_PASSWORD = os.environ.get("DB_PASSWORD")


@app.route("/user")
def get_user():
    # B608 fixed: parameterised query - the driver escapes the value.
    user_id = request.args.get("id", "")
    conn = sqlite3.connect("app.db")
    rows = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchall()
    return jsonify(rows)


@app.route("/ping")
def ping():
    # B602 fixed: no shell, and the argument list is built explicitly so a
    # value like "8.8.8.8; rm -rf /" is one argument, not two commands.
    host = request.args.get("host", "")
    if not host.replace(".", "").isalnum():
        return jsonify(error="invalid host"), 400
    out = subprocess.check_output(["ping", "-c", "1", host], shell=False, timeout=5)
    return jsonify(output=out.decode())


@app.route("/calc")
def calc():
    # B307 fixed: literal_eval parses literals only - it cannot call anything.
    try:
        return jsonify(result=ast.literal_eval(request.args.get("expr", "")))
    except (ValueError, SyntaxError):
        return jsonify(error="invalid expression"), 400


# B301 fixed: the pickle endpoint is removed entirely. Deserialising
# untrusted input is not fixable by validation - JSON is the alternative.


if __name__ == "__main__":
    # B201 fixed: debug off. B104 accepted: 0.0.0.0 is required inside a
    # container, and the container's network policy is the real boundary.
    app.run(host="0.0.0.0", port=5000, debug=False)  # nosec B104

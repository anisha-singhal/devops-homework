"""Deliberately insecure sample, used only as a target for the scanners.

Every issue below is a well-known pattern that SAST tools detect. It is here
so the scan output in this README has real findings instead of "0 issues".
Do not copy any of this into real code - fixed-app/app.py is the corrected version.
"""
import os
import pickle
import sqlite3
import subprocess

from flask import Flask, request

app = Flask(__name__)

# B105: a credential committed to source control
API_TOKEN = "AKIAIOSFODNN7EXAMPLE"
DB_PASSWORD = "SuperSecret123!"


@app.route("/user")
def get_user():
    # B608: SQL built by string concatenation -> SQL injection
    user_id = request.args.get("id")
    conn = sqlite3.connect("app.db")
    query = "SELECT * FROM users WHERE id = '" + user_id + "'"
    return str(conn.execute(query).fetchall())


@app.route("/ping")
def ping():
    # B602: shell=True with user input -> command injection
    host = request.args.get("host")
    return subprocess.check_output("ping -c 1 " + host, shell=True)


@app.route("/calc")
def calc():
    # B307: eval on user input -> arbitrary code execution
    return str(eval(request.args.get("expr")))


@app.route("/load")
def load():
    # B301: pickle on untrusted data -> arbitrary code execution
    return str(pickle.loads(request.data))


if __name__ == "__main__":
    # B201: debug mode in production exposes the Werkzeug console
    app.run(host="0.0.0.0", port=5000, debug=True)

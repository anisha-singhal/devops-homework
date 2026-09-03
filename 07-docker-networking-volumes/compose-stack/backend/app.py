import os

import mysql.connector
from flask import Flask, jsonify

app = Flask(__name__)


def db_connect():
    return mysql.connector.connect(
        host=os.environ.get("DB_HOST", "database"),
        user="root",
        password=os.environ["MYSQL_ROOT_PASSWORD"],
        database=os.environ.get("MYSQL_DATABASE", "demo"),
    )


@app.route("/health")
def health():
    """Readiness probe. Reads only - never writes, so polling this endpoint
    cannot disturb the visit count that the volume-persistence test measures."""
    conn = db_connect()
    cur = conn.cursor()
    cur.execute("SELECT 1")
    cur.fetchone()
    cur.close()
    conn.close()
    return jsonify(status="ok")


@app.route("/")
def index():
    """Prove the backend can reach the database across backend_net."""
    conn = db_connect()
    cur = conn.cursor()
    cur.execute("SELECT VERSION()")
    version = cur.fetchone()[0]

    # A table written here must survive `docker compose down` because
    # /var/lib/mysql is a named volume, not container-local storage.
    cur.execute("CREATE TABLE IF NOT EXISTS visits (id INT AUTO_INCREMENT PRIMARY KEY)")
    cur.execute("INSERT INTO visits VALUES ()")
    conn.commit()

    cur.execute("SELECT COUNT(*) FROM visits")
    count = cur.fetchone()[0]

    cur.close()
    conn.close()
    return jsonify(mysql_version=version, total_visits=count)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)

# ❌ Mã có lỗ hổng: SQL injection + command injection
import subprocess

from sqlalchemy import text


def search_orders(engine, customer: str):
    with engine.connect() as conn:
        # SQL injection: chèn input người dùng thẳng vào câu SQL
        return conn.execute(text(f"SELECT * FROM orders WHERE customer = '{customer}'")).fetchall()


def export_report(filename: str):
    # Command injection: shell=True + input người dùng
    subprocess.run(f"tar czf /tmp/{filename}.tgz /app/reports", shell=True, check=False)

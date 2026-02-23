"""ClassEval evaluation wrapper — runs unittest on predicted class implementations.

Concatenates each prediction with its test code and runs unittest with a 5s
timeout per task. Outputs pass@1 results to stdout.
"""

import json
import subprocess  # noqa: S404  # nosec B404
import sys
import tempfile
from pathlib import Path


def evaluate(samples_path: str, data_path: str) -> dict[str, bool]:
    """Evaluate ClassEval predictions against test cases.

    Returns dict mapping task_id to pass/fail boolean.
    """
    samples = {}
    with open(samples_path, encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.strip()
            if line:
                entry = json.loads(line)
                samples[entry["task_id"]] = entry["predict"][0]

    with open(data_path, encoding="utf-8") as f:
        tasks = {t["task_id"]: t for t in json.load(f)}

    results: dict[str, bool] = {}
    for task_id, prediction in sorted(samples.items()):
        task = tasks[task_id]
        test_code = task["test"]
        import_stmt = task.get("import_statement", [])

        # Build test file: prediction + test code
        parts = []
        if import_stmt:
            if isinstance(import_stmt, list):
                parts.extend(import_stmt)
            else:
                parts.append(import_stmt)
        parts.extend((prediction, test_code))
        test_source = "\n".join(parts)

        with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False, encoding="utf-8") as tmp:
            tmp.write(test_source)
            tmp_path = tmp.name

        try:
            result = subprocess.run(  # noqa: S603  # nosec B603
                [sys.executable, "-m", "pytest", tmp_path, "-x", "--tb=no", "-q"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            passed = result.returncode == 0
        except subprocess.TimeoutExpired:
            passed = False
        finally:
            Path(tmp_path).unlink(missing_ok=True)

        results[task_id] = passed
        status = "PASS" if passed else "FAIL"
        print(f"  {task_id}: {status}")

    return results


def main() -> None:
    """CLI entry point: classeval_wrapper.py <samples.jsonl> <ClassEval_data.json>."""
    if len(sys.argv) != 3:  # noqa: PLR2004
        print(f"Usage: {sys.argv[0]} <samples.jsonl> <ClassEval_data.json>")
        sys.exit(1)

    samples_path = sys.argv[1]
    data_path = sys.argv[2]

    results = evaluate(samples_path, data_path)
    total = len(results)
    passed = sum(1 for v in results.values() if v)
    rate = passed / total if total else 0.0

    print(f"\npass@1: {rate:.4f}")
    print(f"Total: {total}, Passed: {passed}, Failed: {total - passed}")


if __name__ == "__main__":
    main()

"""
Sample Ray workload that exercises tasks and actors to validate the
history-server pipeline end-to-end:

    submit job → collector captures events → S3 → historyserver → dashboard

Usage (from outside the cluster):
    # Port-forward to the Ray head dashboard:
    oc port-forward -n <namespace> svc/<raycluster>-head-svc 8265:8265

    # Submit the job:
    ray job submit --address http://localhost:8265 -- python sample-workload.py

Usage (from inside the head pod):
    oc cp examples/sample-workload.py <namespace>/<head-pod>:/tmp/sample-workload.py -c ray-head
    oc exec -n <namespace> <head-pod> -c ray-head -- python /tmp/sample-workload.py

What it generates (visible in the dashboard after a collector poll cycle):
    - 20 TASK_DEFINITION / TASK_LIFECYCLE events  (from compute_square tasks)
    - ACTOR_DEFINITION / ACTOR_LIFECYCLE events    (from the Counter actor)
    - DRIVER_JOB_DEFINITION / DRIVER_JOB_LIFECYCLE (from the job itself)
"""
import ray
import time
import os


@ray.remote
def compute_square(x: int) -> int:
    """A trivial task that sleeps briefly so the collector has time to capture it."""
    time.sleep(0.5)
    return x * x


@ray.remote
class Counter:
    """A stateful actor that tracks a running total."""

    def __init__(self):
        self.count = 0

    def increment(self, amount: int = 1) -> int:
        self.count += amount
        time.sleep(0.2)
        return self.count

    def get_count(self) -> int:
        return self.count


def main():
    ray.init()

    print("=" * 60)
    print("History Server sample workload")
    print("=" * 60)

    # --- Tasks ---------------------------------------------------------------
    print("\n[1/3] Submitting 20 compute_square tasks...")
    futures = [compute_square.remote(i) for i in range(20)]
    results = ray.get(futures)
    print(f"       Results: {results}")

    # --- Actor ---------------------------------------------------------------
    print("\n[2/3] Creating Counter actor and calling it 10 times...")
    counter = Counter.remote()
    for i in range(1, 11):
        count = ray.get(counter.increment.remote(i))
        print(f"       increment({i}) -> count={count}")

    final = ray.get(counter.get_count.remote())
    print(f"       Final count: {final}")

    # --- Summary -------------------------------------------------------------
    print("\n[3/3] Done!")
    print(f"       Cluster: {os.environ.get('RAY_CLUSTER_NAME', '(unknown)')}")
    print(
        "       Events should appear in the dashboard within ~30-60s "
        "(one collector poll cycle)."
    )
    print("=" * 60)


if __name__ == "__main__":
    main()

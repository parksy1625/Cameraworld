from functools import lru_cache
from uuid import UUID

from redis import Redis
from rq import Queue

from app.config import get_settings

QUEUE_NAME = "cameraworld-reconstruction"
RECONSTRUCTION_TASK = "cameraworld_pipeline.worker.run_reconstruction"


@lru_cache
def get_queue() -> Queue:
    conn = Redis.from_url(get_settings().redis_url)
    return Queue(QUEUE_NAME, connection=conn)


def enqueue_reconstruction(capture_id: UUID, job_id: UUID) -> str:
    """Enqueue a capture for 3D reconstruction.

    The worker lives in the `pipeline` package and imports the task function
    by dotted path, so we enqueue by string reference.
    """
    q = get_queue()
    rq_job = q.enqueue(
        RECONSTRUCTION_TASK,
        str(capture_id),
        str(job_id),
        job_timeout="6h",
        result_ttl=86400,
    )
    return rq_job.id

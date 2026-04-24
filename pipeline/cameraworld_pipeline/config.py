from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class PipelineSettings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Database (shared with backend)
    postgres_user: str = "cameraworld"
    postgres_password: str = "cameraworld"
    postgres_db: str = "cameraworld"
    postgres_host: str = "localhost"
    postgres_port: int = 5432

    # Redis / queue
    redis_url: str = "redis://localhost:6379/0"

    # Object storage
    s3_endpoint: str = "http://localhost:9000"
    s3_region: str = "us-east-1"
    s3_access_key: str = "cameraworld"
    s3_secret_key: str = "cameraworld-secret"
    s3_bucket_captures: str = "cameraworld-captures"
    s3_bucket_artifacts: str = "cameraworld-artifacts"

    # Pipeline tuning
    pipeline_workdir: str = "/tmp/cameraworld-workdir"
    pipeline_frame_fps: float = 3.0
    pipeline_blur_threshold: float = 60.0
    pipeline_max_image_dim: int = 1600
    pipeline_gs_iterations: int = 30000

    # External binaries
    colmap_bin: str = "colmap"
    ffmpeg_bin: str = "ffmpeg"
    gs_repo_path: str = "/opt/gaussian-splatting"

    @property
    def database_url(self) -> str:
        return (
            f"postgresql+psycopg://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )


@lru_cache
def get_settings() -> PipelineSettings:
    return PipelineSettings()

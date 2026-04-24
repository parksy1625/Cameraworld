from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    postgres_user: str = "cameraworld"
    postgres_password: str = "cameraworld"
    postgres_db: str = "cameraworld"
    postgres_host: str = "localhost"
    postgres_port: int = 5432

    redis_url: str = "redis://localhost:6379/0"

    s3_endpoint: str = "http://localhost:9000"
    s3_region: str = "us-east-1"
    s3_access_key: str = "cameraworld"
    s3_secret_key: str = "cameraworld-secret"
    s3_bucket_captures: str = "cameraworld-captures"
    s3_bucket_artifacts: str = "cameraworld-artifacts"
    s3_public_endpoint: str = "http://localhost:9000"

    api_cors_origins: str = Field(default="http://localhost:5173")

    @property
    def database_url(self) -> str:
        return (
            f"postgresql+psycopg://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    @property
    def cors_origins_list(self) -> list[str]:
        return [o.strip() for o in self.api_cors_origins.split(",") if o.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()

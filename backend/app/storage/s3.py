from functools import lru_cache

import boto3
from botocore.client import Config

from app.config import get_settings


class S3Storage:
    def __init__(self, endpoint: str, access_key: str, secret_key: str, region: str):
        self._client = boto3.client(
            "s3",
            endpoint_url=endpoint,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
            region_name=region,
            config=Config(signature_version="s3v4"),
        )

    def presigned_put(self, bucket: str, key: str, content_type: str, expires: int = 3600) -> str:
        return self._client.generate_presigned_url(
            "put_object",
            Params={"Bucket": bucket, "Key": key, "ContentType": content_type},
            ExpiresIn=expires,
        )

    def presigned_get(self, bucket: str, key: str, expires: int = 3600) -> str:
        return self._client.generate_presigned_url(
            "get_object",
            Params={"Bucket": bucket, "Key": key},
            ExpiresIn=expires,
        )

    def head(self, bucket: str, key: str) -> dict:
        return self._client.head_object(Bucket=bucket, Key=key)

    def put_bytes(self, bucket: str, key: str, body: bytes, content_type: str = "application/octet-stream") -> None:
        self._client.put_object(Bucket=bucket, Key=key, Body=body, ContentType=content_type)

    def get_bytes(self, bucket: str, key: str) -> bytes:
        return self._client.get_object(Bucket=bucket, Key=key)["Body"].read()


@lru_cache
def get_storage() -> S3Storage:
    s = get_settings()
    return S3Storage(s.s3_endpoint, s.s3_access_key, s.s3_secret_key, s.s3_region)

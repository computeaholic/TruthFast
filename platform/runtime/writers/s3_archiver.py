# operator/ledger/writers/s3_archiver.py

import os

import boto3


class S3LedgerArchiver:
    def __init__(self, bucket: str, prefix: str, region: str = "us-east-1"):
        self.bucket = bucket
        self.prefix = prefix.rstrip("/")
        self.s3 = boto3.client("s3", region_name=region)

    def archive_file(self, file_path: str):
        day = os.path.basename(file_path)
        key = f"{self.prefix}/{day}"

        self.s3.upload_file(
            file_path,
            self.bucket,
            key,
            ExtraArgs={
                "ServerSideEncryption": "AES256",
                "StorageClass": "STANDARD_IA",
            },
        )

"""Petit utilitaire S3 pour l'agent de sauvegarde : upload, download, latest, prune."""

import datetime as dt
import os
import sys

import boto3
from botocore.config import Config

BUCKET = "backups"


def client():
    return boto3.client(
        "s3",
        endpoint_url=os.environ["S3_ENDPOINT"],
        aws_access_key_id=os.environ["S3_ACCESS_KEY"],
        aws_secret_access_key=os.environ["S3_SECRET_KEY"],
        region_name="eu-west-3",
        config=Config(retries={"max_attempts": 5, "mode": "standard"}, s3={"addressing_style": "path"}),
    )


def list_objects(s3, prefix):
    pages = s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, Prefix=prefix)
    return [obj for page in pages for obj in page.get("Contents", [])]


def main(argv):
    s3 = client()
    action = argv[1]
    if action == "upload":
        s3.upload_file(argv[2], BUCKET, argv[3])
    elif action == "download":
        s3.download_file(BUCKET, argv[2], argv[3])
    elif action == "latest":
        objects = sorted(list_objects(s3, argv[2]), key=lambda o: o["Key"])
        if not objects:
            sys.exit("Aucune sauvegarde trouvée")
        print(objects[-1]["Key"])
    elif action == "prune":
        limit = dt.datetime.now(dt.UTC) - dt.timedelta(days=int(argv[3]))
        for obj in list_objects(s3, argv[2]):
            if obj["LastModified"] < limit:
                s3.delete_object(Bucket=BUCKET, Key=obj["Key"])
                print(f"[backup] Sauvegarde expirée supprimée : {obj['Key']}")
    else:
        sys.exit(f"Action inconnue : {action}")


if __name__ == "__main__":
    main(sys.argv)

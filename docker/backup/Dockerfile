# Agent de sauvegarde : pg_dump (même version majeure que le serveur) + chiffrement + envoi S3
FROM postgres:16.10

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl openssl python3-boto3 \
 && rm -rf /var/lib/apt/lists/*

COPY backup.sh fetch_latest.sh /usr/local/bin/
COPY s3_tool.py /usr/local/bin/s3_tool.py
RUN chmod 755 /usr/local/bin/backup.sh /usr/local/bin/fetch_latest.sh

USER postgres
ENTRYPOINT ["/usr/local/bin/backup.sh"]

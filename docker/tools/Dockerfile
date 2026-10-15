# Image "outils" : scripts Python d'initialisation, de données de démonstration et RGPD
FROM python:3.12-slim

# Utilisateur non root (bonne pratique de sécurité des conteneurs)
RUN useradd --create-home --uid 10001 artelio
WORKDIR /app

COPY docker/tools/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY scripts/*.py /app/scripts/

USER artelio
ENV PYTHONUNBUFFERED=1
CMD ["python", "--version"]

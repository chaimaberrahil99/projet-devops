# Image legere : le build doit rester rapide, vous allez le rejouer 50 fois.
FROM python:3.12-slim

# Pas de .pyc, logs non bufferises (sinon les logs n'arrivent pas dans
# Docker/Kubernetes en temps reel, et l'etape 9 devient un cauchemar).
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Les dependances AVANT le code : le cache Docker est conserve tant que
# requirements.txt ne change pas. Gain enorme sur le temps de pipeline.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

# Ne jamais tourner en root dans un conteneur.
RUN useradd --create-home --uid 10001 appuser
USER appuser

EXPOSE 8000

# Injectee par le pipeline CI (--build-arg puis ENV), affichee par le frontend.
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]

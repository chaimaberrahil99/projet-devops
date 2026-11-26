"""Tests pour le pipeline CI.

Deux familles :
  - les tests sans base : ils tournent TOUJOURS, meme sans service Postgres.
    Garde-fou utile : le pipeline a toujours quelque chose de vert.
  - les tests avec base : ils ne tournent que si DB_HOST est joignable.
    En CI, on fournit un service Postgres (voir ci/ pour la config).
"""

import os

import psycopg2
import pytest
from fastapi.testclient import TestClient

import main

client = TestClient(main.app)


def db_available() -> bool:
    try:
        conn = psycopg2.connect(
            host=main.DB_HOST, port=main.DB_PORT, dbname=main.DB_NAME,
            user=main.DB_USER, password=main.DB_PASSWORD, connect_timeout=2,
        )
        conn.close()
        return True
    except Exception:  # noqa: BLE001
        return False


needs_db = pytest.mark.skipif(not db_available(), reason="pas de base disponible")


# --- Sans base ----------------------------------------------------------------

def test_liveness_ne_depend_pas_de_la_base():
    r = client.get("/health/live")
    assert r.status_code == 200
    assert r.json()["status"] == "alive"


def test_version_exposee():
    r = client.get("/api/version")
    assert r.status_code == 200
    assert r.json()["version"] == os.environ.get("APP_VERSION", "dev")


def test_titre_vide_refuse():
    r = client.post("/api/tasks", json={"title": ""})
    assert r.status_code == 422


# --- Avec base ----------------------------------------------------------------

@needs_db
def test_readiness_ok():
    r = client.get("/health/ready")
    assert r.status_code == 200
    assert r.json()["database"] == "ok"


@needs_db
def test_cycle_complet_creation_lecture_suppression():
    r = client.post("/api/tasks", json={"title": "tache de test"})
    assert r.status_code == 201
    task_id = r.json()["id"]

    r = client.get("/api/tasks")
    assert r.status_code == 200
    assert any(t["id"] == task_id for t in r.json())

    r = client.delete(f"/api/tasks/{task_id}")
    assert r.status_code == 204

    r = client.get("/api/tasks")
    assert all(t["id"] != task_id for t in r.json())


@needs_db
def test_suppression_inexistante_renvoie_404():
    r = client.delete("/api/tasks/999999")
    assert r.status_code == 404


@needs_db
def test_stats_agrege_correctement():
    r = client.get("/api/stats")
    assert r.status_code == 200
    data = r.json()
    # Coherence interne : les totaux doivent s'additionner.
    assert data["total"] == data["done"] + data["pending"]
    assert data["total"] == sum(c["total"] for c in data["by_category"])
    assert data["done"] == sum(c["done"] for c in data["by_category"])
    assert 0 <= data["completion_rate"] <= 100
    assert len(data["by_category"]) >= 1
    for c in data["by_category"]:
        assert 1.0 <= c["avg_priority"] <= 3.0


@needs_db
def test_creation_avec_priorite_et_categorie():
    r = client.post("/api/tasks",
                    json={"title": "tache data", "priority": 1, "category": "tests"})
    assert r.status_code == 201
    body = r.json()
    assert body["priority"] == 1
    assert body["category"] == "tests"
    client.delete(f"/api/tasks/{body['id']}")


def test_priorite_hors_bornes_refusee():
    r = client.post("/api/tasks", json={"title": "x", "priority": 9})
    assert r.status_code == 422

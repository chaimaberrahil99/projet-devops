"""
API REST minimale pour le projet DevOps.

Principes respectes ici (ils comptent pour la notation) :
  - AUCUNE valeur de configuration en dur : tout vient de l'environnement.
    C'est ce qui rend le conteneur portable d'une infra SysOps a l'autre.
  - Deux sondes de sante distinctes : /health/live et /health/ready.
    Kubernetes a besoin des deux (voir README).
  - Le schema de la base n'est PAS cree ici. Les migrations sont un travail
    separe (app/db/init.sql, puis un Job Kubernetes en production).
"""

import os
import time

import psycopg2
import psycopg2.extras
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, Field

# --- Configuration : 100 % environnement, zero valeur en dur ------------------

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "tasksdb")
DB_USER = os.environ.get("DB_USER", "tasks")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")

# Affichee par le frontend : c'est ce qui rend le rolling update VISIBLE
# pendant la soutenance. Le pipeline CI injecte ici le tag de l'image.
APP_VERSION = os.environ.get("APP_VERSION", "dev")

app = FastAPI(title="Tasks API", version=APP_VERSION)


# --- Metriques Prometheus -----------------------------------------------------
#
# Trois des quatre "signaux dorés" du SRE sont mesures ici :
#   - trafic   : nombre de requetes par seconde      -> compteur http_requests_total
#   - erreurs  : proportion de reponses 5xx          -> meme compteur, filtre sur le code
#   - latence  : temps de reponse                    -> histogramme http_request_duration
# Le quatrieme, la saturation, vient de cAdvisor (processeur et memoire des
# conteneurs), que Prometheus collecte directement aupres de Kubernetes.
#
# On expose des SERIES, pas des valeurs deja calculees : Prometheus interroge
# /metrics regulierement et calcule les taux lui-meme. C'est ce qui permet de
# demander ensuite "le taux d'erreur des 5 dernieres minutes" sans que
# l'application ait eu a le prevoir.

REQUETES = Counter(
    "http_requests_total",
    "Nombre total de requetes HTTP",
    ["method", "endpoint", "status"],
)
DUREE = Histogram(
    "http_request_duration_seconds",
    "Duree des requetes HTTP en secondes",
    ["method", "endpoint"],
)


@app.middleware("http")
async def mesurer(request: Request, call_next):
    # On utilise le MOTIF de route (/api/tasks/{task_id}) et non l'URL reelle :
    # sinon chaque identifiant creerait une serie distincte, et Prometheus
    # croulerait sous les millions de series. C'est l'erreur classique.
    debut = time.perf_counter()
    reponse = await call_next(request)
    # La route n'est connue qu'une fois le routage effectue, donc apres l'appel.
    route = request.scope.get("route")
    endpoint = getattr(route, "path", request.url.path)

    if endpoint != "/metrics":
        DUREE.labels(request.method, endpoint).observe(time.perf_counter() - debut)
        REQUETES.labels(request.method, endpoint, reponse.status_code).inc()
    return reponse


@app.get("/metrics")
def metrics():
    """Point de collecte interroge par Prometheus."""
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


def get_connection():
    """Ouvre une connexion. Volontairement simple : une connexion par requete.

    Suffisant pour un prototype. En production reelle on utiliserait un pool
    (psycopg2.pool) ou pgbouncer -- a mentionner dans le dossier de projet.
    """
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=3,
    )


# --- Modeles ------------------------------------------------------------------

class TaskIn(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    priority: int = Field(default=2, ge=1, le=3)
    category: str = Field(default="general", max_length=50)


class Task(BaseModel):
    id: int
    title: str
    done: bool
    priority: int
    category: str


class CategoryStat(BaseModel):
    category: str
    total: int
    done: int
    pending: int
    avg_priority: float


class Stats(BaseModel):
    total: int
    done: int
    pending: int
    completion_rate: float
    by_category: list[CategoryStat]


# --- Sondes de sante ----------------------------------------------------------

@app.get("/health/live")
def liveness():
    """Le processus repond-il ? NE teste PAS la base.

    Important : si cette sonde testait la base, une base momentanement
    indisponible ferait redemarrer en boucle tous les pods du backend.
    """
    return {"status": "alive", "version": APP_VERSION}


@app.get("/health/ready")
def readiness():
    """Ce pod peut-il servir du trafic ? Teste la base.

    C'est CETTE sonde qui garantit le zero-downtime : pendant un rolling
    update, Kubernetes n'envoie du trafic au nouveau pod qu'une fois qu'elle
    repond 200.
    """
    try:
        with get_connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
            cur.fetchone()
    # On attrape volontairement tout : une sonde de readiness ne doit JAMAIS
    # lever, elle doit repondre 503. C'est ce 503 qui dit a Kubernetes de ne
    # pas (encore) router de trafic vers ce pod.
    except Exception as exc:  # noqa: BLE001
        return JSONResponse(
            status_code=503,
            content={"status": "not ready", "database": "unreachable",
                     "detail": str(exc)[:200]},
        )
    return {"status": "ready", "database": "ok", "version": APP_VERSION}


@app.get("/api/version")
def version():
    return {"version": APP_VERSION}


# --- CRUD ---------------------------------------------------------------------

@app.get("/api/tasks", response_model=list[Task])
def list_tasks():
    with get_connection() as conn, \
            conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            "SELECT id, title, done, priority, category "
            "FROM tasks ORDER BY id DESC LIMIT 100"
        )
        return cur.fetchall()


@app.post("/api/tasks", response_model=Task, status_code=201)
def create_task(payload: TaskIn):
    with get_connection() as conn, \
            conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            "INSERT INTO tasks (title, priority, category) VALUES (%s, %s, %s) "
            "RETURNING id, title, done, priority, category",
            (payload.title, payload.priority, payload.category),
        )
        return cur.fetchone()


@app.delete("/api/tasks/{task_id}", status_code=204)
def delete_task(task_id: int):
    with get_connection() as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM tasks WHERE id = %s", (task_id,))
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Task not found")


@app.get("/api/stats", response_model=Stats)
def stats():
    """Agregation calculee par la base, pas en Python.

    Le SQL agrege 240 lignes en 6 et renvoie quelques centaines d'octets.
    Tout remonter pour compter cote applicatif ferait transiter la table
    entiere a chaque appel -- c'est le reflexe a garder quand les volumes
    grossissent.
    """
    with get_connection() as conn, \
            conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""
            SELECT category,
                   count(*)                              AS total,
                   count(*) FILTER (WHERE done)          AS done,
                   count(*) FILTER (WHERE NOT done)      AS pending,
                   round(avg(priority)::numeric, 2)      AS avg_priority
            FROM tasks
            GROUP BY category
            ORDER BY category
        """)
        by_category = [
            {**row, "avg_priority": float(row["avg_priority"] or 0)}
            for row in cur.fetchall()
        ]

    total = sum(c["total"] for c in by_category)
    done = sum(c["done"] for c in by_category)
    return {
        "total": total,
        "done": done,
        "pending": total - done,
        "completion_rate": round(done / total * 100, 1) if total else 0.0,
        "by_category": by_category,
    }

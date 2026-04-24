.PHONY: help up down logs api worker viewer pipeline-smoke test-backend test-pipeline fmt lint

help:
	@echo "Cameraworld — available targets:"
	@echo "  make up              start local stack (postgres, redis, minio, api, worker)"
	@echo "  make down            stop local stack"
	@echo "  make logs            tail stack logs"
	@echo "  make api             run API only in foreground"
	@echo "  make worker          run pipeline worker only"
	@echo "  make viewer          run web viewer dev server"
	@echo "  make pipeline-smoke  run end-to-end pipeline smoke test on sample data"
	@echo "  make test-backend    run backend unit tests"
	@echo "  make test-pipeline   run pipeline unit tests"
	@echo "  make fmt             ruff + prettier formatting"

up:
	docker compose -f infra/docker-compose.yml --env-file .env up -d --build

down:
	docker compose -f infra/docker-compose.yml --env-file .env down

logs:
	docker compose -f infra/docker-compose.yml --env-file .env logs -f --tail=200

api:
	cd backend && uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

worker:
	cd pipeline && python -m cameraworld_pipeline.worker

viewer:
	cd viewer && npm run dev

pipeline-smoke:
	cd pipeline && python -m cameraworld_pipeline.orchestrator --input tests/fixtures/sample_capture --output /tmp/cameraworld-smoke

test-backend:
	cd backend && pytest -q

test-pipeline:
	cd pipeline && pytest -q

fmt:
	cd backend && ruff format . && ruff check --fix .
	cd pipeline && ruff format . && ruff check --fix .
	cd viewer && npx prettier --write src

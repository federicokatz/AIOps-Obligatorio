# Instrucciones para agentes — Obligatorio AIOps

Este repo es un fork del proyecto de ejemplo (PharmaGo) del curso electivo AIOps. **El obligatorio se trabaja por encima del proyecto ya hecho**: el foco es DevOps, despliegue, resiliencia, telemetría, incidentes y caos. **No es un obligatorio de desarrollo de software.**

Antes de trabajar, leer [docs/objetivo-obligatorio.md](docs/objetivo-obligatorio.md) (letra, rúbrica, plazos y estado).

## Restringido: código .NET y Angular (lógica de negocio y frontend)

El docente advirtió que leer la lógica de negocio quema tokens sin aportar nada. Reglas, también para subagentes:

1. **Configuración: se puede leer y editar.** Ejemplos: `appsettings*.json`, `*.csproj`, `global.json`, `angular.json`, `package.json`, `tsconfig*.json`, `nginx.conf`, `Dockerfile`, YAML, `.env`, workflows de CI.
2. **Código fuente: no leer, buscar por contenido (Grep) ni editar sin permiso.** Aplica a `*.cs` (todo el Backend .NET, incluidos tests) y a `*.ts`, `*.html`, `*.scss`, `*.css` del Frontend Angular. También a `package-lock.json` y a los dumps `*.bak`/`*.sql` de `Implementacion K8S/Base de Datos/`.
   - Para hacerlo, el agente debe **pedir permiso al usuario y dar las razones**: qué archivo exacto, qué necesita saber o cambiar y por qué no alcanza con la documentación o la configuración. Sin respuesta afirmativa, no lo abre.
   - El permiso vale para ese archivo y ese motivo, no es general.
   - Leer solo lo necesario (rangos acotados), nunca carpetas enteras.
3. **No lanzar agentes exploradores** (Explore, general-purpose, etc.) sobre el repo para "entender el proyecto" o "mapear el código". Tampoco construir grafos/índices del código (nada de `/graphify` sobre el repo).
4. Si hace falta saber qué hace un servicio, usar primero lo documentado (README, tutoriales, manifiestos, `docs/`) y la configuración; si no alcanza, seguir el punto 2. Nunca deducirlo recorriendo el código por cuenta propia.
5. Los cambios de código de negocio deben ser mínimos y justificados (p. ej. exponer `/health` en el gateway) y requieren el mismo permiso previo.

## Permitido (aquí está el trabajo)

- `Implementacion K8S/Codigo/k8s/` — manifiestos, overlays (`local`, `multinode`), scripts de aplicación, configmaps.
- `Implementacion K8S/Codigo/chaos-engineering/` — scripts de caos.
- `Implementacion K8S/Codigo/grafana/`, `Backend/otel-collector-config.yaml`, `Backend/prometheus.yml` — telemetría y alertas.
- `Dockerfile`s, `docker-compose.yml`, `nginx.conf`, `.github/workflows/` — build, imágenes y CI/CD.
- Documentación: `*.md` del repo, `docs/` y `Implementacion K8S/Codigo/tutoriales/`. **Los `.md` son la fuente de conocimiento del proyecto**: leerlos antes de preguntar por cómo funciona algo. Incluye las guías `.md` de `Backend/` (`RATE_LIMITING_GUIDE.md`, `MICROSERVICES_MIGRATION_SUMMARY.md`, `explicacion-volumenes.md`), `QUICKSTART.md`, `k8s/README-k8s.md` y `chaos-engineering/README.md`. Cubren: Prometheus/métricas, Grafana, logs en Kibana, logs estructurados, rate limiting y su script de prueba (`tutoriales/rate-limit/`).
- Nuevos artefactos del obligatorio: scripts de ML (Isolation Forest, SVM RBF), runbooks, diagramas, evidencias.

Para ubicar archivos usar `git ls-files`, `ls` o Glob por **nombre**; el Grep por contenido no se usa sobre código `.cs`/Angular.

## Reglas de trabajo

- **Subagentes: solo modelo Haiku** (`model: "haiku"`), y solo si de verdad hacen falta; para tareas puntuales de búsqueda sobre las carpetas permitidas.
- **Preguntar antes de asumir** ante cualquier duda de alcance, rama o decisión de diseño.
- Ramas: `main` (base del profesor), `develop` (integración, entra por PR). Trabajar en `feature/*`. No commitear ni hacer push sin que el usuario lo pida.
- Scripts del repo en Bash y PowerShell (el equipo usa Windows + Minikube/WSL2). Mantener paridad `.sh`/`.ps1` cuando exista.
- Registrar evidencia (CSV, capturas, resultados) en `docs/evidencias/` y no reemplazar resultados fallidos por conclusiones sin registro.
- Honestidad en el informe: separar lo medido de lo supuesto (p. ej. Minikube multinodo local ≠ nodos físicos distintos).
- Uso de IA: la letra exige citar herramientas y contexto de uso en el informe. Anotar en `docs/` qué se hizo con IA. Todo lo generado debe revisarse; el equipo defiende oralmente (defensa eliminatoria).
- Verificar cambios con `kubectl kustomize overlays/<perfil>` y los chequeos del CI antes de dar algo por terminado.

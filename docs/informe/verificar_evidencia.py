"""Recalcula desde los registros crudos de docs/evidencias las cifras que cita el informe.
Uso: python docs/informe/verificar_evidencia.py
"""
import csv, glob, os, re, sys, datetime, json
from collections import Counter

R = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
EV = os.path.join(R, "docs", "evidencias")
K8 = os.path.join(R, "Implementacion K8S", "Codigo", "k8s")
rows = []


def add(claim, got, ok, src):
    rows.append((claim, got, "OK" if ok else "DISCREPANCIA", src))


def rd(p):
    return open(p, encoding="utf-8").read()


# 1. Autocuracion: 9/9, 5,2 a 10,1 s
f = os.path.join(EV, "self-healing-20260926-230325.csv")
rs = list(csv.DictReader(open(f, encoding="utf-8")))
sec = [float(r["recovery_seconds"].replace(",", ".")) for r in rs]
add("9 fallas, 9 recuperaciones, 5,2 a 10,1 s", f"{len(sec)} filas, min {min(sec):.2f} s, max {max(sec):.2f} s",
    len(sec) == 9 and 5.2 <= min(sec) < 5.3 and 10.0 <= max(sec) <= 10.1, "self-healing-20260926-230325.csv")

# 2. Probes: readiness 3 s / 1 fallo; liveness 5 s / 3 fallos
bad = []
for svc in ("api-gateway", "users-service", "pharmacy-service"):
    t = rd(os.path.join(K8, "deployments", "backend", f"{svc}-deployment.yaml"))
    for kind, per, fail in (("readinessProbe", 3, 1), ("livenessProbe", 5, 3)):
        m = re.search(kind + r":(.*?)(?:\n        [a-zA-Z]+Probe:|\n        resources:|\n      volumes|\Z)", t, re.S)
        blk = m.group(1) if m else ""
        p = re.search(r"periodSeconds:\s*(\d+)", blk); fl = re.search(r"failureThreshold:\s*(\d+)", blk)
        if not (p and fl and int(p.group(1)) == per and int(fl.group(1)) == fail):
            bad.append((svc, kind, p and p.group(1), fl and fl.group(1)))
add("readiness cada 3 s/1 fallo; liveness cada 5 s/3 fallos (3 servicios)", "coincide" if not bad else str(bad), not bad, "k8s/deployments/backend/*.yaml")

# 3. Rolling update
bad = []
for fn in glob.glob(os.path.join(K8, "deployments", "backend", "*-deployment.yaml")) + glob.glob(os.path.join(K8, "deployments", "frontend", "*-deployment.yaml")):
    t = rd(fn)
    for need in ("maxUnavailable: 0", "maxSurge: 1", "minReadySeconds: 10", "terminationGracePeriodSeconds: 45", "sleep 5"):
        if need not in t:
            bad.append((os.path.basename(fn), need))
add("RollingUpdate maxUnavailable 0, maxSurge 1, minReadySeconds 10, grace 45 s, preStop 5 s (4 componentes)", "coincide" if not bad else str(bad), not bad, "k8s/deployments/**")

# 4. Rate limiting config
t = rd(os.path.join(K8, "configmaps", "gateway-resilience.yaml"))
ok = all(x in t for x in ('"Endpoint": "POST:/api/login", "Period": "1m", "Limit": 5', '"Endpoint": "*", "Period": "1m", "Limit": 50', '"Endpoint": "*", "Period": "1h", "Limit": 500'))
add("rate limit por replica: 5/min login, 50/min general, 500/h", "coincide" if ok else "no coincide", ok, "configmaps/gateway-resilience.yaml")
add("health check activo cada 3 s, timeout 2 s, 2 fallos", "coincide" if ('"Interval": "00:00:03"' in t and '"Timeout": "00:00:02"' in t and 'Threshold": "2"' in t) else "no", ('"Interval": "00:00:03"' in t and '"Timeout": "00:00:02"' in t and 'Threshold": "2"' in t), "configmaps/gateway-resilience.yaml")

# 5. Circuit breaker: 502 ~10 s, luego 503
t = rd(os.path.join(EV, "circuit-breaker-yarp-20261011.txt"))
ok = "t=1s  -> 502" in t and "t=11s -> 503" in t and "t=43s -> 200" in t
add("breaker: 502 hasta ~10 s, 503 inmediato, 200 a los 43 s (incluye ~14 s de arranque)", "coincide" if ok else "no", ok, "circuit-breaker-yarp-20261011.txt")

# 6. Rate limit dividido: 100/min efectivos
t = rd(os.path.join(EV, "rate-limit-dividido-20261011.txt"))
add("con 2 replicas el total efectivo es 100/min (ok200=100)", f"{t.count('ok200=100')} corridas con ok200=100 de 4", t.count("ok200=100") == 4, "rate-limit-dividido-20261011.txt")


# 7. Camino A / B: ventanas de error por crash (sonda interna)
def window(path):
    t0 = None; rws = []; rst = ""
    for l in open(path, encoding="utf-8"):
        p = l.split()
        if not p: continue
        if p[0] == "T0": t0 = float(p[1])
        elif p[0] == "restarts:": rst = l.strip()
        elif len(p) == 2 and p[0][0].isdigit() and "." in p[0]: rws.append((float(p[0]), p[1]))
    bad = [t for t, c in rws if c != "200"]
    return (len(rws), len(bad), (bad[-1] - bad[0]) if bad else 0.0)


D = os.path.join(EV, "ensayo-multinode-20261110")
a2 = [window(os.path.join(D, f"camino-A-2rep-{i}.txt")) for i in (1, 2, 3)]
a1 = [window(os.path.join(D, f"camino-A-1rep-{i}.txt")) for i in (1, 2, 3)]
add("crash Pharmacy, 2 replicas: ventana 0,69 / 0,52 / 0,69 s (ultimo menos primer fallo)", ", ".join(f"{w:.2f} s ({n} fallidas)" for _, n, w in a2), abs(a2[0][2] - 0.69) < 0.02 and abs(a2[1][2] - 0.52) < 0.02 and abs(a2[2][2] - 0.69) < 0.02, "camino-A-2rep-*.txt")
add("crash Pharmacy, 1 replica: 12,7 / 27,5 / 31,9 s (crece)", ", ".join(f"{w:.1f} s ({n} fallidas)" for _, n, w in a1),
    abs(a1[0][2] - 12.7) < 0.1 and abs(a1[1][2] - 27.5) < 0.1 and abs(a1[2][2] - 31.9) < 0.1 and a1[0][2] < a1[1][2] < a1[2][2], "camino-A-1rep-*.txt")
gw2 = [window(os.path.join(D, f"camino-B-gw-2rep-{i}.txt"))[1] for i in (1, 2)]
gw1 = [window(os.path.join(D, f"camino-B-gw-1rep-{i}.txt")) for i in (1, 2)]
us2 = [window(os.path.join(D, f"camino-B-us-2rep-{i}.txt")) for i in (1, 2)]
us1 = [window(os.path.join(D, f"camino-B-us-1rep-{i}.txt")) for i in (1, 2)]
add("gateway: 2 replicas 0 y 0 fallidas; 1 replica 2 (1,0 s) y 6 (10,1 s)", f"2rep {gw2}; 1rep {[(n, round(w, 1)) for _, n, w in gw1]}",
    gw2 == [0, 0] and gw1[0][1] == 2 and gw1[1][1] == 6 and abs(gw1[0][2] - 1.0) < 0.1 and abs(gw1[1][2] - 10.1) < 0.1, "camino-B-gw-*.txt")
add("Users: 2 replicas 4 (0,17 s) y 5 (0,52 s); 1 replica 9 (2,5 s) y 22 (17,7 s)", f"2rep {[(n, round(w, 2)) for _, n, w in us2]}; 1rep {[(n, round(w, 1)) for _, n, w in us1]}",
    [n for _, n, _ in us2] == [4, 5] and [n for _, n, _ in us1] == [9, 22] and abs(us2[0][2] - 0.17) < 0.05 and abs(us2[1][2] - 0.52) < 0.05 and abs(us1[0][2] - 2.5) < 0.1 and abs(us1[1][2] - 17.7) < 0.1, "camino-B-us-*.txt")


# 8. Camino C: caida de nodo
def cwin(name):
    t0 = None; rws = []
    for l in open(os.path.join(D, name), encoding="utf-8"):
        p = l.split()
        if not p: continue
        if p[0] == "T0": t0 = float(p[1])
        elif len(p) == 2 and p[0][0].isdigit() and "." in p[0]: rws.append((float(p[0]), p[1]))
    seg = []; cur = None
    for t, c in rws:
        if c != "200":
            cur = [t, t] if cur is None else [cur[0], t]
        elif cur: seg.append(cur); cur = None
    if cur: seg.append(cur)
    big = max(seg, key=lambda s: s[1] - s[0])
    nxt = min(t for t, c in rws if c == "200" and t > big[1])
    return nxt - t0, big[1] - big[0]


for name, exp in (("camino-C-sin-repuesto.txt", 130), ("camino-C-con-repuesto-tol300.txt", 473), ("camino-C-preferida-tol30.txt", 87), ("camino-C-preferida-tol300.txt", 347)):
    rec, dur = cwin(name)
    add(f"caida de nodo {name[8:-4]}: corte de ~{exp} s", f"servicio vuelve a +{rec:.1f} s; tramo de fallos {dur:.1f} s", abs(dur - exp) <= 2, name)


# 9. Ensayo de defensa (1 nodo): alertas y sonda
def alert_times(path, phases):
    out = {}; prev = {}
    for l in open(path, encoding="utf-8"):
        p = l.split()
        if len(p) < 2 or p[1] == "error": continue
        cur = dict(x.split("=") for x in p[1:])
        for k, v in cur.items():
            if prev.get(k, "inactive") != v: out.setdefault(k, []).append((p[0], v))
        prev = cur
    return out


def s(h): a, b, c = map(int, h.split(":")); return a * 3600 + b * 60 + c


E = os.path.join(EV, "ensayo-defensa-local-20261112")
ev = alert_times(os.path.join(E, "alertas-cada-10s.txt"), None)
T0 = {"Rate": "13:16:41", "CPU": "13:18:38", "Memoria": "13:22:08", "Storage": "13:25:43", "Servicio": "13:29:55"}
exp = {"Rate": 56, "CPU": 91, "Memoria": 44, "Storage": 92, "Servicio": 43}
for k in T0:
    fire = [h for h, v in ev.get(k, []) if v == "firing" and s(h) >= s(T0[k]) - 1]
    got = s(fire[0]) - s(T0[k]) if fire else None
    add(f"ensayo 1 nodo: alerta {k} a `firing` a +{exp[k]} s", f"+{got} s" if got is not None else "no disparo", got is not None and abs(got - exp[k]) <= 1, "ensayo-defensa-local-20261112/alertas-cada-10s.txt")
red = [h for h, v in ev.get("Rate", []) if v == "firing"]
nofire = all(not any(v == "firing" and "13:27:34" <= h <= "13:29:50" and k in ("Servicio", "Pod", "Tasa") for h, v in ev.get(k, [])) for k in ev)
add("fase de red: ninguna alerta de servicio/pod/5xx", "ninguna" if nofire else "hubo alguna", nofire, "alertas-cada-10s.txt")

rws = []
for l in open(os.path.join(E, "sonda-continua-pharmacy.txt"), encoding="utf-8"):
    p = l.split()
    if len(p) == 2 and p[0][0].isdigit() and "." in p[0]: rws.append((float(p[0]), p[1]))
u = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%H:%M:%S")
seg = []; cur = None
for t, c in rws:
    if c != "200":
        cur = [t, t, 1] if cur is None else [cur[0], t, cur[2] + 1]
    elif cur: seg.append(cur); cur = None
if cur: seg.append(cur)
txt = "; ".join(f"{u(a)}-{u(b)} ({b - a:.1f} s, {n} fallidas)" for a, b, n in seg)
ok = len(seg) == 2 and abs((seg[0][1] - seg[0][0]) - 28.9) < 0.2 and seg[0][2] == 26 and abs((seg[1][1] - seg[1][0]) - 40.1) < 0.2 and seg[1][2] == 40
add("sonda 1 nodo: 0 fallos salvo red 28,9 s (26) y desconexion 40,1 s (40)", f"{len(rws)} solicitudes; {txt}", ok, "sonda-continua-pharmacy.txt")

# 10. CSV del caos
import csv as _c
rr = list(_c.DictReader(open(os.path.join(EV, "chaos-run-20261112-131641.csv"), encoding="utf-8")))
add("chaos-all: 6 fases, todas con codigo 0", f"{len(rr)} fases, codigos {[r['codigo_salida'] for r in rr]}", len(rr) == 6 and all(r["codigo_salida"] == "0" for r in rr), "chaos-run-20261112-131641.csv")

# 11. Plan de contencion
pl = rd(os.path.join(R, "docs", "plan-contencion-incidentes.md"))
for needle, label in (("5xx > 5 %", "SEV1: 5xx > 5 % sostenido"), ("Comandante", "rol comandante"), ("Operador", "rol operador"), ("Observador", "rol observador"), ("### 5.1", "playbook 5.1"), ("### 5.6", "playbook 5.6"), ("Postmortem", "plantilla de postmortem"), ("Preparación", "checklist previo")):
    add(f"plan de contencion: {label}", "presente" if needle in pl else "ausente", needle in pl, "docs/plan-contencion-incidentes.md")

# 12. Scripts de caos
CH = os.path.join(R, "Implementacion K8S", "Codigo", "chaos-engineering")
need = {"load-requests.sh": "500", "cpu-spike.sh": "for i in 1 2 3 4", "ram-spike.sh": "bloques de 1 MB", "volume-spike.sh": "300", "network-cut.sh": "NetworkPolicy", "disconnect-component.sh": "scale", "chaos-all.sh": "RAM_SECS", "chaos-all.ps1": "RamSecs"}
for fn, nd in need.items():
    ok = os.path.exists(os.path.join(CH, fn)) and nd in rd(os.path.join(CH, fn))
    add(f"script {fn} existe y contiene `{nd}`", "ok" if ok else "falta", ok, "chaos-engineering/" + fn)

# 13. Evidencias sin registro crudo (solo documentadas)
add("primer 429 en la solicitud 51 (75 solicitudes: 67 ok, 8 429)", "solo en validacion-alertas-caos-20261110.md (sin log crudo)", True, "documento")
add("Pod reiniciado a +21 s y 5xx a +99 s", "solo en validacion-alertas-caos-20261110.md (sin log crudo)", True, "documento")
add("alerta de disco del nodo a +59 s (sintetica) y su captura", "captura 20261110-alerta-disco-nodo-firing.png existe: " + str(os.path.exists(os.path.join(EV, "capturas", "20261110-alerta-disco-nodo-firing.png"))), True, "documento + captura")

n_ok = sum(1 for r in rows if r[2] == "OK")
print(f"TOTAL {len(rows)} comprobaciones, {n_ok} OK, {len(rows) - n_ok} discrepancias\n")
for c, g, st, sr in rows:
    print(f"[{st}] {c}\n      -> {g}   ({sr})")

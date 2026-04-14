#!/usr/bin/env python3
"""
Configure Uptime Kuma après déploiement.
Usage: configure_kuma.py <url> <user> <password> <monitors_json>
"""
import sys
import json
import time

try:
    from uptime_kuma_api import UptimeKumaApi, MonitorType
except ImportError:
    print("  ! uptime-kuma-api non installé", file=sys.stderr)
    sys.exit(1)

def get_monitor_type(mon_type):
    return {
        "http":  MonitorType.HTTP,
        "tcp":   MonitorType.TCP_PING,
        "ping":  MonitorType.PING,
    }.get(mon_type, MonitorType.HTTP)

def main():
    if len(sys.argv) < 5:
        print(f"Usage: {sys.argv[0]} <url> <user> <password> <monitors_json>")
        sys.exit(1)

    kuma_url  = sys.argv[1]
    kuma_user = sys.argv[2]
    kuma_pass = sys.argv[3]
    monitors  = json.loads(sys.argv[4])

    api = UptimeKumaApi(kuma_url, wait_events=3, timeout=30)

    # Création du compte admin ou connexion
    try:
        api.setup(kuma_user, kuma_pass)
        print(f"  ✓ Compte admin créé ({kuma_user})")
    except Exception as setup_err:
        try:
            api.login(kuma_user, kuma_pass)
            print(f"  ✓ Connecté ({kuma_user})")
        except Exception as login_err:
            print(f"  ✗ Auth échouée: setup={setup_err} / login={login_err}", file=sys.stderr)
            api.disconnect()
            sys.exit(1)

    # Monitors existants
    try:
        existing = {m["name"] for m in api.get_monitors()}
    except Exception as e:
        print(f"  ! get_monitors: {e}", file=sys.stderr)
        existing = set()

    added = 0
    for mon in monitors:
        name     = mon.get("name", "")
        mon_type = mon.get("type", "http")

        if name in existing:
            print(f"  ~ {name}: déjà existant")
            continue

        try:
            if mon_type == "http":
                api.add_monitor(
                    type=MonitorType.HTTP,
                    name=name,
                    url=mon["url"],
                    interval=60,
                    retryInterval=60,
                    maxretries=3,
                )
            else:
                api.add_monitor(
                    type=MonitorType.TCP_PING,
                    name=name,
                    hostname=mon["hostname"],
                    port=mon.get("port", 80),
                    interval=60,
                    retryInterval=60,
                    maxretries=3,
                )
            print(f"  + {name}")
            added += 1
            time.sleep(0.5)
        except Exception as e:
            print(f"  ! {name}: {e}", file=sys.stderr)

    api.disconnect()
    print(f"  → {added} monitor(s) ajouté(s) sur {len(monitors)} attendu(s).")
    return 0

if __name__ == "__main__":
    sys.exit(main())

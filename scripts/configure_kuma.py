#!/usr/bin/env python3
"""
Configure Uptime Kuma après déploiement.
Usage: configure_kuma.py <url> <user> <password> <monitors_json>

monitors_json = JSON array de monitors:
  [{"name": "Apache", "type": "http", "url": "http://1.2.3.4"}, ...]
"""
import sys
import json
import time

try:
    from uptime_kuma_api import UptimeKumaApi, MonitorType
except ImportError:
    print("  ! uptime-kuma-api non installé (pip3 install uptime-kuma-api)", file=sys.stderr)
    sys.exit(1)

def get_monitor_type(mon_type):
    mapping = {
        "http":  MonitorType.HTTP,
        "tcp":   MonitorType.TCP_PING,
        "ping":  MonitorType.PING,
        "dns":   MonitorType.DNS,
    }
    return mapping.get(mon_type, MonitorType.HTTP)

def main():
    if len(sys.argv) < 5:
        print(f"Usage: {sys.argv[0]} <url> <user> <password> <monitors_json>")
        sys.exit(1)

    kuma_url   = sys.argv[1]
    kuma_user  = sys.argv[2]
    kuma_pass  = sys.argv[3]
    monitors   = json.loads(sys.argv[4])

    api = UptimeKumaApi(kuma_url, wait_events=3, timeout=30)

    # Création du compte admin ou connexion
    try:
        api.setup(kuma_user, kuma_pass)
    except Exception:
        try:
            api.login(kuma_user, kuma_pass)
        except Exception as e:
            print(f"  ! Authentification échouée: {e}", file=sys.stderr)
            api.disconnect()
            sys.exit(1)

    # Récupérer les monitors existants
    try:
        existing = {m["name"] for m in api.get_monitors()}
    except Exception:
        existing = set()

    # Ajouter les monitors
    added = 0
    for mon in monitors:
        name = mon.get("name", "")
        if name in existing:
            print(f"  ~ {name}: déjà existant")
            continue
        try:
            kwargs = {
                "type":          get_monitor_type(mon.get("type", "http")),
                "name":          name,
                "interval":      mon.get("interval", 60),
                "retryInterval": mon.get("interval", 60),
                "maxretries":    mon.get("maxretries", 3),
            }
            if mon.get("type", "http") in ("http", None):
                kwargs["url"] = mon["url"]
            elif mon.get("type") in ("tcp", "ping"):
                kwargs["hostname"] = mon["hostname"]
                kwargs["port"]     = mon.get("port", 80)

            api.add_monitor(**kwargs)
            print(f"  + {name}: {mon.get('url', mon.get('hostname', ''))}")
            added += 1
            time.sleep(0.5)
        except Exception as e:
            print(f"  ! {name}: {e}", file=sys.stderr)

    api.disconnect()
    print(f"  {added} monitor(s) ajouté(s).")
    return 0

if __name__ == "__main__":
    sys.exit(main())

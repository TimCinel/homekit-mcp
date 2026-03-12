#!/usr/bin/env python3

import argparse
import csv
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Tuple


DEFAULT_OUTPUT_DIR = "artifacts"
UNKNOWN_SERIALS = {"", "Unknown", "unknown", "UNKNOWN"}


@dataclass
class Accessory:
    name: str
    serial: str
    room: str
    uuid: str


@dataclass
class PlanRow:
    name: str
    serial: str
    current_room: str
    target_room: str
    reason: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plan and apply HomeKit room moves using homekitctl and hass-cli."
    )
    parser.add_argument("--input-csv", help="Optional CSV with columns name,serial,room.")
    parser.add_argument(
        "--restore",
        help="Restore from a saved snapshot CSV with columns name,serial,room. Alias for --input-csv.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply planned room moves via homekitctl move.",
    )
    parser.add_argument(
        "--apply-plan",
        help="Apply an existing plan CSV with columns name,serial,current_room,target_room,reason.",
    )
    parser.add_argument(
        "--output-dir",
        default=DEFAULT_OUTPUT_DIR,
        help=f"Directory for generated CSV files. Default: {DEFAULT_OUTPUT_DIR}",
    )
    parser.add_argument(
        "--env-file",
        default="env.source",
        help="Optional shell-style env file with lines like export KEY=value.",
    )
    return parser.parse_args()


def load_env_file(path: Path) -> Dict[str, str]:
    loaded: Dict[str, str] = {}
    if not path.exists():
        return loaded

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :]
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        loaded[key.strip()] = value.strip()
    return loaded


def cleaned_env(env_file: str) -> Dict[str, str]:
    env = os.environ.copy()
    env.update(load_env_file(Path(env_file)))
    env.pop("LC_ALL", None)
    env["LANG"] = env.get("LANG") or "en_AU.UTF-8"
    env["LC_CTYPE"] = env.get("LC_CTYPE") or env["LANG"]
    return env


def run_json(command: List[str], env: Dict[str, str]) -> object:
    proc = subprocess.run(command, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        raise RuntimeError(
            f"Command failed ({proc.returncode}): {' '.join(command)}\n{proc.stderr.strip()}"
        )

    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"Command did not return JSON: {' '.join(command)}\n{proc.stdout[:500]}"
        ) from exc


def run_text(command: List[str], env: Dict[str, str]) -> str:
    proc = subprocess.run(command, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        raise RuntimeError(
            f"Command failed ({proc.returncode}): {' '.join(command)}\n{proc.stderr.strip()}"
        )
    return proc.stdout


def get_homekit_accessories(env: Dict[str, str]) -> List[Accessory]:
    payload = run_json(["homekitctl", "--json", "accessories"], env)
    items = payload["result"]["_meta"]["accessories"]
    return [
        Accessory(
            name=item.get("name", ""),
            serial=item.get("serial_number", "") or "",
            room=item.get("room", "") or "",
            uuid=item.get("uuid", "") or "",
        )
        for item in items
    ]


def get_homekit_rooms(env: Dict[str, str]) -> List[str]:
    payload = run_json(["homekitctl", "--json", "rooms"], env)
    items = payload["result"]["_meta"]["rooms"]
    return sorted(item.get("name", "") for item in items if item.get("name"))


def get_ha_registry(kind: str, env: Dict[str, str]) -> List[dict]:
    payload = run_json(["hass-cli", "-o", "json", "raw", "ws", kind], env)
    if isinstance(payload, dict) and isinstance(payload.get("result"), list):
        return payload["result"]
    raise RuntimeError(f"Unexpected hass-cli output for {kind}")


def load_ha_entity_data(env: Dict[str, str]) -> Tuple[set[str], Dict[str, str]]:
    entity_registry = get_ha_registry("config/entity_registry/list", env)
    device_registry = get_ha_registry("config/device_registry/list", env)
    area_registry = get_ha_registry("config/area_registry/list", env)

    area_by_id = {item["area_id"]: item["name"] for item in area_registry if item.get("area_id")}
    device_area_by_id = {
        item["id"]: area_by_id.get(item.get("area_id"), "")
        for item in device_registry
        if item.get("id")
    }

    entity_ids: set[str] = set()
    room_by_entity: Dict[str, str] = {}
    for entity in entity_registry:
        entity_id = entity.get("entity_id")
        if not entity_id:
            continue
        entity_ids.add(entity_id)

        area_name = area_by_id.get(entity.get("area_id"), "")
        if not area_name:
            area_name = device_area_by_id.get(entity.get("device_id"), "")
        if area_name:
            room_by_entity[entity_id] = area_name
    return entity_ids, room_by_entity


def is_known_serial(serial: str) -> bool:
    return serial not in UNKNOWN_SERIALS


def load_csv_rows(path: Path) -> List[dict]:
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    required = {"name", "serial", "room"}
    if not rows:
        return []
    missing = required - set(rows[0].keys())
    if missing:
        raise RuntimeError(f"CSV {path} is missing columns: {', '.join(sorted(missing))}")
    return rows


def load_plan_rows(path: Path) -> List[PlanRow]:
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))

    required = {"name", "serial", "current_room", "target_room", "reason"}
    if not rows:
        return []
    missing = required - set(rows[0].keys())
    if missing:
        raise RuntimeError(f"Plan CSV {path} is missing columns: {', '.join(sorted(missing))}")

    return [
        PlanRow(
            name=row.get("name", "") or "",
            serial=row.get("serial", "") or "",
            current_room=row.get("current_room", "") or "",
            target_room=row.get("target_room", "") or "",
            reason=row.get("reason", "") or "",
        )
        for row in rows
    ]


def key_for_row(name: str, serial: str) -> Tuple[str, str]:
    if is_known_serial(serial):
        return ("serial", serial)
    return ("name", name)


def build_loaded_room_map(rows: Iterable[dict]) -> Dict[Tuple[str, str], str]:
    loaded: Dict[Tuple[str, str], str] = {}
    for row in rows:
        loaded[key_for_row(row.get("name", ""), row.get("serial", ""))] = row.get("room", "") or ""
    return loaded


def merge_reason(existing: str, new_reason: str) -> str:
    parts = [part for part in existing.split(";") if part]
    if new_reason not in parts:
        parts.append(new_reason)
    return ";".join(parts)


def build_plan(
    accessories: List[Accessory],
    loaded_room_map: Dict[Tuple[str, str], str],
    ha_entity_ids: set[str],
    ha_room_map: Dict[str, str],
    valid_rooms: set[str],
) -> List[PlanRow]:
    plan: List[PlanRow] = []

    for accessory in accessories:
        key = key_for_row(accessory.name, accessory.serial)
        target_room = ""
        reason = ""

        loaded_room = loaded_room_map.get(key, "")
        if loaded_room:
            target_room = loaded_room
            reason = merge_reason(reason, "loaded-csv")

        if is_known_serial(accessory.serial):
            ha_room = ha_room_map.get(accessory.serial, "")
            in_homeassistant = accessory.serial in ha_entity_ids
            if ha_room and ha_room in valid_rooms and not target_room:
                target_room = ha_room
                reason = merge_reason(reason, "homeassistant-room")
            elif ha_room and ha_room in valid_rooms:
                reason = merge_reason(reason, "homeassistant-room")
            elif ha_room:
                reason = merge_reason(reason, "homeassistant-room-no-homekit-match")
            elif in_homeassistant:
                reason = merge_reason(reason, "homeassistant-no-room")
            else:
                reason = merge_reason(reason, "not-homeassistant")
        else:
            reason = merge_reason(reason, "not-homeassistant")

        plan.append(
            PlanRow(
                name=accessory.name,
                serial=accessory.serial,
                current_room=accessory.room,
                target_room=target_room,
                reason=reason,
            )
        )

    return plan


def timestamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def write_plan_csv(path: Path, rows: List[PlanRow]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["name", "serial", "current_room", "target_room", "reason"],
        )
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    "name": row.name,
                    "serial": row.serial,
                    "current_room": row.current_room,
                    "target_room": row.target_room,
                    "reason": row.reason,
                }
            )


def write_snapshot_csv(path: Path, accessories: List[Accessory]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["name", "serial", "room"])
        writer.writeheader()
        for item in accessories:
            writer.writerow({"name": item.name, "serial": item.serial, "room": item.room})


def apply_moves(rows: List[PlanRow], valid_rooms: set[str], env: Dict[str, str]) -> int:
    moves = 0
    for row in rows:
        if not row.target_room or row.current_room == row.target_room:
            continue
        if row.target_room not in valid_rooms:
            print(
                f"Skipping '{row.name}': target room '{row.target_room}' does not exist in HomeKit",
                file=sys.stderr,
            )
            continue

        run_text(["homekitctl", "move", row.name, row.target_room], env)
        moves += 1
    return moves


def main() -> int:
    try:
        args = parse_args()
        env = cleaned_env(args.env_file)

        output_dir = Path(args.output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)

        stamp = timestamp()
        rooms = set(get_homekit_rooms(env))

        if args.apply_plan:
            plan_path = Path(args.apply_plan)
            plan = load_plan_rows(plan_path)
            move_candidates = [row for row in plan if row.target_room]
            print(f"Loaded plan CSV: {plan_path}")
            print(f"Rows in plan: {len(plan)}")
            print(f"Planned moves: {len(move_candidates)}")
            moves = apply_moves(plan, rooms, env)
        else:
            input_csv = args.restore or args.input_csv
            loaded_rows = load_csv_rows(Path(input_csv)) if input_csv else []
            accessories = get_homekit_accessories(env)

            loaded_room_map = build_loaded_room_map(loaded_rows)
            ha_entity_ids, ha_room_map = load_ha_entity_data(env)
            plan = build_plan(accessories, loaded_room_map, ha_entity_ids, ha_room_map, rooms)
            plan = [row for row in plan if row.current_room != row.target_room]

            plan_path = output_dir / f"homekit-plan-{stamp}.csv"
            write_plan_csv(plan_path, plan)

            move_candidates = [row for row in plan if row.target_room]

            print(f"Wrote plan CSV: {plan_path}")
            print(f"Accessories scanned: {len(accessories)}")
            print(f"Planned moves: {len(move_candidates)}")

            if not args.apply:
                print("Dry run only. Re-run with --apply to move accessories.")
                return 0

            moves = apply_moves(plan, rooms, env)

        final_accessories = get_homekit_accessories(env)
        snapshot_path = output_dir / f"homekit-snapshot-{stamp}.csv"
        write_snapshot_csv(snapshot_path, final_accessories)

        print(f"Moves applied: {moves}")
        print(f"Wrote snapshot CSV: {snapshot_path}")
        return 0
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

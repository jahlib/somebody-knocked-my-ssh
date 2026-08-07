#!/usr/bin/env python3
"""Безопасное объединение перечисленных IPv4-адресов в CIDR-подсети."""

from __future__ import annotations

import argparse
import ipaddress
import sys
from collections.abc import Iterable
from pathlib import Path

IPv4Address = ipaddress.IPv4Address
IPv4Network = ipaddress.IPv4Network


def parse_lines(lines: Iterable[str]) -> tuple[set[IPv4Address], set[IPv4Network]]:
    """Разбирает строки, отделяя одиночные адреса от явно заданных подсетей."""
    addresses: set[IPv4Address] = set()
    networks: set[IPv4Network] = set()

    for line_number, raw_line in enumerate(lines, start=1):
        value = raw_line.split("#", 1)[0].strip()
        if not value:
            continue

        try:
            if "/" in value:
                network = ipaddress.ip_network(value, strict=False)
                if not isinstance(network, IPv4Network):
                    raise ValueError("поддерживается только IPv4")
                networks.add(network)
            else:
                address = ipaddress.ip_address(value)
                if not isinstance(address, IPv4Address):
                    raise ValueError("поддерживается только IPv4")
                addresses.add(address)
        except ValueError as error:
            raise ValueError(f"строка {line_number}: {value!r}: {error}") from error

    return addresses, networks


def process(lines: Iterable[str]) -> list[IPv4Address | IPv4Network]:
    """Сортирует записи и сворачивает полные последовательности в подсети."""
    addresses, supplied_networks = parse_lines(lines)
    networks = supplied_networks | {
        IPv4Network((address, 32)) for address in addresses
    }

    # collapse_addresses сортирует записи, удаляет вложенные сети и объединяет
    # соседние блоки только тогда, когда они полностью образуют общий CIDR.
    collapsed = ipaddress.collapse_addresses(networks)

    # /32 нужен только для расчёта. В результате одиночный IP выводится без /32.
    return [
        network.network_address if network.prefixlen == 32 else network
        for network in collapsed
    ]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Сортирует IPv4-записи и объединяет их в минимальный точный набор "
            "CIDR-подсетей, не добавляя отсутствующие адреса."
        )
    )
    parser.add_argument("input", type=Path, help="исходный файл, одна запись в строке")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="выходной файл (по умолчанию результат выводится в stdout)",
    )

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    try:
        with args.input.open(encoding="utf-8") as source:
            result = process(source)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Ошибка: {error}", file=sys.stderr)
        return 1

    text = "".join(f"{network}\n" for network in result)
    try:
        if args.output:
            args.output.write_text(text, encoding="utf-8")
        else:
            sys.stdout.write(text)
    except OSError as error:
        print(f"Ошибка записи: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

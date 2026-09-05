#!/usr/bin/env python3
"""Seed the history store with representative transcriptions for screenshots.

Writes straight into the Core Data SQLite file (a programmatic model, so there
is no .xcdatamodel to go through). The app must not be running.
"""
import datetime
import sqlite3
import sys
import uuid

# Core Data stores dates as seconds since 2001-01-01 UTC.
CORE_DATA_EPOCH = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)

# Everyday dictation, the kind of thing the app is actually used for.
SAMPLES = [
    ("Напомни, пожалуйста, отправить отчёт до конца недели и приложить таблицу с расходами.", 7.4, 6),
    ("Встречаемся завтра в двенадцать у входа, если планы поменяются — напиши.", 5.1, 42),
    ("Идея для статьи: как локальное распознавание речи работает без интернета и не отправляет данные на сервер.", 9.8, 95),
    ("Купить хлеб, молоко, кофе и что-нибудь к чаю.", 3.6, 180),
    ("Спасибо за созвон, зафиксировал все договорённости, к пятнице пришлю черновик.", 6.2, 320),
]


def main(db_path: str) -> None:
    now = datetime.datetime.now(datetime.timezone.utc)
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("DELETE FROM ZTRANSCRIPTIONRECORDENTITY")
    for pk, (text, duration, minutes_ago) in enumerate(SAMPLES, start=1):
        when = (now - datetime.timedelta(minutes=minutes_ago) - CORE_DATA_EPOCH).total_seconds()
        cur.execute(
            "INSERT INTO ZTRANSCRIPTIONRECORDENTITY "
            "(Z_PK, Z_ENT, Z_OPT, ZDATE, ZDURATION, ZLANGUAGE, ZMODELUSED, ZTEXT, ZID) "
            "VALUES (?,1,1,?,?,?,?,?,?)",
            (pk, when, duration, "ru", "small", text, uuid.uuid4().bytes),
        )
    # Core Data hands out primary keys from this table; leaving it behind would
    # make the app collide with the rows seeded here.
    cur.execute(
        "UPDATE Z_PRIMARYKEY SET Z_MAX=? WHERE Z_NAME='TranscriptionRecordEntity'",
        (len(SAMPLES),),
    )
    con.commit()
    con.close()
    print(f"  seeded {len(SAMPLES)} history records")


if __name__ == "__main__":
    main(sys.argv[1])

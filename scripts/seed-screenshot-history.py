#!/usr/bin/env python3
"""Seed the history store with representative transcriptions for screenshots.

    seed-screenshot-history.py <Corvin.sqlite> [ru|en|es]

Writes straight into the Core Data SQLite file (a programmatic model, so there
is no .xcdatamodel to go through). The app must not be running.
"""
import datetime
import sqlite3
import sys
import uuid

# Core Data stores dates as seconds since 2001-01-01 UTC.
CORE_DATA_EPOCH = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)

# Everyday dictation, the kind of thing the app is actually used for. The same
# five situations in each language rather than translations of a fixed English
# original — a screenshot should read as if someone had dictated it.
SAMPLES = {
    "ru": [
        ("Напомни, пожалуйста, отправить отчёт до конца недели и приложить таблицу с расходами.", 7.4, 6),
        ("Встречаемся завтра в двенадцать у входа, если планы поменяются — напиши.", 5.1, 42),
        ("Идея для статьи: как локальное распознавание речи работает без интернета и не отправляет данные на сервер.", 9.8, 95),
        ("Купить хлеб, молоко, кофе и что-нибудь к чаю.", 3.6, 180),
        ("Спасибо за созвон, зафиксировал все договорённости, к пятнице пришлю черновик.", 6.2, 320),
    ],
    "en": [
        ("Remind me to send the report before the end of the week and attach the expenses spreadsheet.", 7.4, 6),
        ("Let's meet tomorrow at twelve by the entrance — text me if the plans change.", 5.1, 42),
        ("Article idea: how on-device speech recognition works with no internet and never sends your data to a server.", 9.8, 95),
        ("Buy bread, milk, coffee and something to go with the tea.", 3.6, 180),
        ("Thanks for the call, I have noted everything we agreed and will send a draft by Friday.", 6.2, 320),
    ],
    "es": [
        ("Recuérdame enviar el informe antes de que acabe la semana y adjuntar la hoja de gastos.", 7.4, 6),
        ("Quedamos mañana a las doce en la entrada; si cambian los planes, escríbeme.", 5.1, 42),
        ("Idea para un artículo: cómo el reconocimiento de voz en el dispositivo funciona sin internet y no envía tus datos a ningún servidor.", 9.8, 95),
        ("Comprar pan, leche, café y algo para acompañar el té.", 3.6, 180),
        ("Gracias por la llamada, he anotado todo lo acordado y el viernes te envío un borrador.", 6.2, 320),
    ],
}


def main(db_path: str, language: str) -> None:
    samples = SAMPLES.get(language)
    if samples is None:
        sys.exit(f"no sample transcriptions for '{language}' — add them to SAMPLES")
    now = datetime.datetime.now(datetime.timezone.utc)
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("DELETE FROM ZTRANSCRIPTIONRECORDENTITY")
    for pk, (text, duration, minutes_ago) in enumerate(samples, start=1):
        when = (now - datetime.timedelta(minutes=minutes_ago) - CORE_DATA_EPOCH).total_seconds()
        cur.execute(
            "INSERT INTO ZTRANSCRIPTIONRECORDENTITY "
            "(Z_PK, Z_ENT, Z_OPT, ZDATE, ZDURATION, ZLANGUAGE, ZMODELUSED, ZTEXT, ZID) "
            "VALUES (?,1,1,?,?,?,?,?,?)",
            (pk, when, duration, language, "small", text, uuid.uuid4().bytes),
        )
    # Core Data hands out primary keys from this table; leaving it behind would
    # make the app collide with the rows seeded here.
    cur.execute(
        "UPDATE Z_PRIMARYKEY SET Z_MAX=? WHERE Z_NAME='TranscriptionRecordEntity'",
        (len(samples),),
    )
    con.commit()
    con.close()
    print(f"  seeded {len(samples)} history records in {language}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "ru")

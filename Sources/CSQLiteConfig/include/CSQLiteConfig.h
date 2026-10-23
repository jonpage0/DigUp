#ifndef CSQLITECONFIG_H
#define CSQLITECONFIG_H

// SQLite's settings Swift can't make: sqlite3_db_config is variadic. The connection is SQLite's own (`sqlite3 *`).

struct sqlite3;

/// Sets the connection never to move its write-ahead log into the database file when it closes, even as the last one
/// to have it open (SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE). SQLITE_OK when it's set.
int digup_sqlite3_no_checkpoint_on_close(struct sqlite3 *db);

#endif

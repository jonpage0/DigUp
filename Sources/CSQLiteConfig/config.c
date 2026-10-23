#include "CSQLiteConfig.h"
#include <sqlite3.h>   // the system's on macOS, the vendored one (CSQLite) elsewhere

int digup_sqlite3_no_checkpoint_on_close(struct sqlite3 *db) {
    int set = 0;
    int status = sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, &set);
    if (status != SQLITE_OK) return status;
    return set == 1 ? SQLITE_OK : SQLITE_ERROR;
}

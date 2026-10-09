"""Write a full backup of the database to the path in BACKUP_PATH.

    BACKUP_PATH=/var/lib/brainfreeze/backups/x.dbf.gz gemdb node/backup.py

Run by bin/backup, which uploads it. A fresh `gemdb` session is clean, so
`gemdb.admin.backup` -- which refuses while there is uncommitted work --
writes everything committed up to now.
"""

import os

import gemdb.admin

gemdb.admin.backup(os.environ["BACKUP_PATH"])
print("Wrote %s." % os.environ["BACKUP_PATH"])

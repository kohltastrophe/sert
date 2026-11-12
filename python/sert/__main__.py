import sys

if sys.version_info < (3, 11):
    print(f"sert: needs Python 3.11 or newer; this is {sys.version.split()[0]} ({sys.executable})", file=sys.stderr)
    sys.exit(2)

from sert.cli import main

sys.exit(main())

"""Allow running the CLI as ``python -m ospc_to_flex_k8``."""
import sys
from .cli import main

sys.exit(main())

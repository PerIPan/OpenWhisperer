import os
import sys

_HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.abspath(os.path.join(_HERE, "..", "servers")))
sys.path.insert(0, os.path.abspath(os.path.join(_HERE, "..", "scripts")))

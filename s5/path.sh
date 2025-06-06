# Contenido de spanish_openslr_ft/s5/path.sh
export KALDI_ROOT="/home/draken/projects/kaldi" 
if [ -f "$KALDI_ROOT/tools/env.sh" ]; then . "$KALDI_ROOT/tools/env.sh"; fi
export PATH="$PWD/utils/:$KALDI_ROOT/tools/openfst/bin:$PWD:$PATH"
COMMON_PATH_FILE="$KALDI_ROOT/tools/config/common_path.sh"
if [ ! -f "$COMMON_PATH_FILE" ]; then echo "ERROR..." >&2; exit 1; fi
. "$COMMON_PATH_FILE" 
export LC_ALL=C
export PYTHONUNBUFFERED=1
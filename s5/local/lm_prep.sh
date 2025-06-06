#!/usr/bin/env bash

# lm_prep.sh
# Prepara el modelo de lenguaje n-gram.

if [ -z "$KALDI_ROOT" ]; then
    echo "Error (lm_prep.sh): La variable KALDI_ROOT no está definida."
    if [ -f ../path.sh ]; then . ../path.sh; elif [ -f ./path.sh ]; then . ./path.sh; fi
    if [ -z "$KALDI_ROOT" ]; then echo "Error (lm_prep.sh): No se pudo establecer KALDI_ROOT."; exit 1; fi
fi

# Crear directorios temporales necesarios
mkdir -p data/local/tmp

# --- Encontrar ngram-count de SRILM ---
SRILM_ROOT="$KALDI_ROOT/tools/srilm"
NGRAM_COUNT_EXE=""
srilm_bin_archs=("i686-m64" "x86_64-linux-gnu" "i686") 
LM_TEXT_INPUT="data/local/tmp/lm_corpus_for_srilm.txt" 

if [ ! -f "$LM_TEXT_INPUT" ]; then
    echo "ERROR (lm_prep.sh): Archivo de texto para LM '$LM_TEXT_INPUT' no encontrado."
    echo "                 Asegúrate de que lang_prep.sh (Etapa 1) lo haya creado."
    exit 1
fi

for arch in "${srilm_bin_archs[@]}"; do
    if [ -f "$SRILM_ROOT/bin/$arch/ngram-count" ]; then
        NGRAM_COUNT_EXE="$SRILM_ROOT/bin/$arch/ngram-count"
        echo "INFO (lm_prep.sh): Usando ngram-count de: $NGRAM_COUNT_EXE"
        break
    fi
done

if [ -z "$NGRAM_COUNT_EXE" ]; then
    echo
    echo "[!] ERROR (lm_prep.sh): SRILM ngram-count no encontrado."
    echo "    Buscado en arquitecturas bajo $SRILM_ROOT/bin/: ${srilm_bin_archs[*]}"
    echo "    Asegúrate de que SRILM esté instalado y compilado en '$KALDI_ROOT/tools/'."
    echo "    Intenta: cd '$KALDI_ROOT/tools' && ./install_srilm.sh \"Tu Nombre\" \"Tu Org\" tu@email \"Ciudad, Pais\""
    echo
    exit 1
fi


# --- Construir el Modelo de Lenguaje ARPA ---
LM_ARPA_FILE="data/local/tmp/3gram_train_dev_test.arpa.gz" # Nombre de archivo más descriptivo
VOCAB_FILE="data/local/tmp/lm_vocab.txt"
ORDER=3 # Trigrama

echo "INFO (lm_prep.sh): Construyendo modelo de lenguaje ARPA de orden $ORDER usando $LM_TEXT_INPUT..."
"$NGRAM_COUNT_EXE" -lm "$LM_ARPA_FILE" \
    -order "$ORDER" \
    -write-vocab "$VOCAB_FILE" \
    -sort \
    -wbdiscount \
    -unk \
    -map-unk "<UNK>" \
    -text "$LM_TEXT_INPUT" || { echo "ERROR (lm_prep.sh): ngram-count falló."; exit 1; } # <--- USA LA VARIABLE

if [ ! -s "$LM_ARPA_FILE" ]; then # -s comprueba si el archivo existe y no está vacío
    echo "ERROR (lm_prep.sh): El archivo ARPA del LM ($LM_ARPA_FILE) no se creó o está vacío."
    exit 1
fi
echo "INFO (lm_prep.sh): Modelo ARPA generado en $LM_ARPA_FILE"

# --- Convertir ARPA LM a FST (G.fst) ---
lang_dir_with_G="data/lang_test_tg" 
mkdir -p "$lang_dir_with_G" # Asegurar que el directorio de salida exista

echo "INFO (lm_prep.sh): Convirtiendo ARPA LM a FST (G.fst) en $lang_dir_with_G..."
# utils/format_lm.sh espera el directorio lang base (data/lang), el ARPA LM,
# el lexicon.txt (para obtener words.txt), y el directorio de SALIDA.
if [ ! -f data/local/dict/lexicon.txt ]; then
    echo "ERROR (lm_prep.sh): data/local/dict/lexicon.txt no encontrado. ¿Se ejecutó lang_prep.sh?"
    exit 1
fi
if [ ! -d data/lang ]; then
    echo "ERROR (lm_prep.sh): data/lang no encontrado. ¿Se ejecutó prepare_lang.sh?"
    exit 1
fi

utils/format_lm.sh data/lang \
    "$LM_ARPA_FILE" \
    data/local/dict/lexicon.txt \
    "$lang_dir_with_G" || { echo "ERROR (lm_prep.sh): utils/format_lm.sh falló."; exit 1; }

if [ ! -f "$lang_dir_with_G/G.fst" ]; then
    echo "ERROR (lm_prep.sh): $lang_dir_with_G/G.fst no fue creado."
    exit 1
fi

echo "INFO (lm_prep.sh): G.fst creado exitosamente en $lang_dir_with_G/G.fst"
echo "=== Preparación del Modelo de Lenguaje Finalizada ==="
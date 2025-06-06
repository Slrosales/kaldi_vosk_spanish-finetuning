#!/usr/bin/env bash

# lang_prep.sh modificado para usar un lexicón base y G2P (Epitran) para OOVs y jerga

mkdir -p data/local/dict
mkdir -p data/local/tmp

# --- Configuración ---
BASE_LEXICON_ORIGINAL="data/local/base_lexicon_openslr.txt"           # TU ARCHIVO DE LEXICÓN DE OPENSLR
PREPROCESS_LEX_SCRIPT="local/preprocess_base_lexicon.py"              # Script para normalizar el lexicón base
BASE_LEXICON_NORMALIZED="data/local/dict/lexicon_base_normalized.txt" # Archivo preprocesado
JERGA_TECNICA_RAW="data/local/jerga_tecnica_raw.txt"                  # Palabras de jerga, una por línea, SIN NORMALIZAR
JERGA_TECNICA_NORMALIZED="data/local/dict/jerga_tecnica_normalized.txt"
G2P_PYTHON_SCRIPT="local/g2p_epitran.py"             # Ruta a tu script de Epitran
NORMALIZE_PYTHON_SCRIPT="local/normalize_unicode.py" # Ruta a tu script de normalización de texto

# Nombre del archivo de corpus de texto unificado que usará el LM
# Este archivo se creará aquí y lm_prep.sh lo leerá.
LM_CORPUS_NORMALIZED_FOR_SRILM="data/local/tmp/lm_corpus_for_srilm.txt"

export LC_ALL=C.UTF-8

# --- Verificar Scripts Necesarios ---
if [ ! -f "$NORMALIZE_PYTHON_SCRIPT" ]; then
    echo "Error: Script de normalización $NORMALIZE_PYTHON_SCRIPT no encontrado."
    exit 1
fi
if [ ! -f "$G2P_PYTHON_SCRIPT" ]; then
    echo "Error: Script G2P $G2P_PYTHON_SCRIPT no encontrado."
    exit 1
fi
if [ ! -f "$PREPROCESS_LEX_SCRIPT" ]; then
    echo "Error: Script $PREPROCESS_LEX_SCRIPT no encontrado."
    exit 1
fi
if [ ! -f "$BASE_LEXICON_ORIGINAL" ]; then
    echo "Error: Lexicón base original $BASE_LEXICON_ORIGINAL no encontrado."
    exit 1
fi
# Crear archivo de jerga si no existe (para que el script no falle)
touch "$JERGA_TECNICA_RAW"

# 1. Crear vocabulario desde los datos de entrenamiento
# PASO 1: Crear texto unificado para el Modelo de Lenguaje (LM) y, a partir de él,
#         extraer el vocabulario normalizado para la creación del Lexicón.
echo "Paso 1: Creando corpus de texto unificado para LM y extrayendo vocabulario para Lexicón..."

# 1a. Combinar transcripciones de train y test (excluyendo IDs de utterance).
cat data/train/text data/test/text | cut -d' ' -f2- >data/local/tmp/lm_corpus_raw.txt ||
    {
        echo "ERROR: Falló la creación de lm_corpus_raw.txt"
        exit 1
    }

# 1b. Normalizar este corpus crudo usando tu script de Python.
#     El resultado es el texto que alimentará a SRILM (ngram-count).
python3 "$NORMALIZE_PYTHON_SCRIPT" <data/local/tmp/lm_corpus_raw.txt >"$LM_CORPUS_NORMALIZED_FOR_SRILM" ||
    {
        echo "ERROR: Falló la normalización del corpus para LM."
        exit 1
    }
echo "  Corpus para LM normalizado y guardado en: $LM_CORPUS_NORMALIZED_FOR_SRILM"

# 1c. De ESTE MISMO corpus normalizado para el LM, extraer el vocabulario único.
#     Este vocabulario será la base para construir tu lexicon.txt.
#     Esto asegura que cualquier palabra que el LM vea, también estará considerada para el lexicón.
cat "$LM_CORPUS_NORMALIZED_FOR_SRILM" | tr -s ' ' '\n' |
    grep -v -E "^$|^\s*$" | sort -u >data/local/dict/vocab_from_data_normalized.txt ||
    {
        echo "ERROR: Falló la extracción de vocabulario de $LM_CORPUS_NORMALIZED_FOR_SRILM"
        exit 1
    }

# 2. Normalizar el BASE_LEXICON_ORIGINAL (solo la columna de la palabra)
echo "Paso 2: Normalizando el lexicón base: $BASE_LEXICON_ORIGINAL con $PREPROCESS_LEX_SCRIPT..."
if python3 "$PREPROCESS_LEX_SCRIPT" "$BASE_LEXICON_ORIGINAL" >"$BASE_LEXICON_NORMALIZED"; then
    echo "  Lexicón base normalizado guardado en $BASE_LEXICON_NORMALIZED"
else
    echo "ERROR: Falló la normalización de $BASE_LEXICON_ORIGINAL con $PREPROCESS_LEX_SCRIPT."
    exit 1
fi
if [ -s "$BASE_LEXICON_ORIGINAL" ] && [ ! -s "$BASE_LEXICON_NORMALIZED" ]; then
    echo "ADVERTENCIA: $BASE_LEXICON_NORMALIZED está vacío después de la normalización, pero $BASE_LEXICON_ORIGINAL no lo estaba."
fi

# 3. Normalizar JERGA_TECNICA_RAW
echo "Paso 3: Normalizando archivo de jerga técnica..."
if [ -s "$JERGA_TECNICA_RAW" ]; then # Solo procesar si el archivo de jerga no está vacío
    cat "$JERGA_TECNICA_RAW" | python3 "$NORMALIZE_PYTHON_SCRIPT" | sort -u >"$JERGA_TECNICA_NORMALIZED" ||
        {
            echo "ERROR: Falló la normalización de la jerga técnica."
            exit 1
        }
    echo "  Jerga técnica normalizada guardada en $JERGA_TECNICA_NORMALIZED"
else
    echo "  Archivo de jerga técnica ($JERGA_TECNICA_RAW) está vacío. Creando $JERGA_TECNICA_NORMALIZED vacío."
    touch "$JERGA_TECNICA_NORMALIZED" # Asegurar que el archivo exista aunque esté vacío
fi

# 4. Preparar lexicon.txt inicial con entradas especiales
echo "Paso 4: Creando lexicon.txt inicial..."
{
    echo "!SIL sil"
    echo "<UNK> spn"
} >data/local/dict/lexicon.txt

# 5. Añadir palabras del vocabulario de datos que SÍ están en el lexicón base normalizado
echo "Procesando vocabulario de datos contra lexicón base..."
# Este awk solo se encarga de tomar las pronunciaciones del lexicón base
# para las palabras que SÍ existen en nuestro vocabulario de datos.
awk '
    # Bloque 1: Lee todas las palabras del vocabulario de datos y las marca para encontrar
    FNR==NR { vocab_words_to_find[$1]=1; next }
    ($1 in vocab_words_to_find) { print }
    ' data/local/dict/vocab_from_data_normalized.txt "$BASE_LEXICON_NORMALIZED" >>data/local/dict/lexicon.txt

# PASO 6 MODIFICADO COMPLETAMENTE:
# Identificar palabras OOV (del vocabulario de datos que NO estaban en el lexicón base)
# y combinarlas con la jerga para G2P.

echo "Identificando palabras OOV de los datos y combinando con jerga..."
rm -f data/local/dict/combined_oov_for_g2p.txt  
rm -f data/local/dict/oov_from_data.txt         
rm -f data/local/dict/words_in_base_lexicon.txt 

# Primero, necesitamos una lista de solo las PALABRAS (primera columna) del lexicón base normalizado.
# Asegúrate de que BASE_LEXICON_NORMALIZED se haya creado correctamente en el paso 2.
if [ -f "$BASE_LEXICON_NORMALIZED" ]; then
    awk '{print $1}' "$BASE_LEXICON_NORMALIZED" | sort -u >data/local/dict/words_in_base_lexicon.txt
else
    echo "Advertencia: $BASE_LEXICON_NORMALIZED no existe. No se pueden determinar OOV contra el lexicón base."
    # Crear un archivo vacío para que comm no falle, pero no habrá OOV de esta fuente.
    touch data/local/dict/words_in_base_lexicon.txt
fi

if [ -f data/local/dict/vocab_from_data_normalized.txt ]; then
    comm -23 data/local/dict/vocab_from_data_normalized.txt data/local/dict/words_in_base_lexicon.txt >data/local/dict/oov_from_data.txt
else
    echo "Advertencia: vocab_from_data_normalized.txt no existe. No se pueden determinar OOV de los datos."
    # Crear un archivo vacío para que el cat posterior no falle.
    touch data/local/dict/oov_from_data.txt
fi

# Limpiar el archivo temporal de palabras del lexicón base
rm -f data/local/dict/words_in_base_lexicon.txt

# Combinar las OOV encontradas (de oov_from_data.txt) con la jerga técnica normalizada
# (JERGA_TECNICA_NORMALIZED ya fue creada y ordenada con sort -u en el paso 3).
cat data/local/dict/oov_from_data.txt "$JERGA_TECNICA_NORMALIZED" >data/local/dict/combined_oov_for_g2p.txt

# Limpiar el archivo de OOV de los datos, ya que su contenido está en combined_oov_for_g2p.txt
rm -f data/local/dict/oov_from_data.txt

# Filtrar <UNK> y !SIL si accidentalmente se colaron en la lista combinada, y ordenar
if [ -f data/local/dict/combined_oov_for_g2p.txt ]; then
    grep -v -E "^!SIL$|^<UNK>$" data/local/dict/combined_oov_for_g2p.txt |
        sort -u >data/local/dict/combined_oov_for_g2p_sorted.txt

    # Solo mover si el archivo ordenado se creó y no está vacío (o si el original no estaba vacío)
    if [ -s data/local/dict/combined_oov_for_g2p_sorted.txt ] || [ -s data/local/dict/combined_oov_for_g2p.txt ]; then
        mv data/local/dict/combined_oov_for_g2p_sorted.txt data/local/dict/combined_oov_for_g2p.txt
    else
        # Si ambos están vacíos o el sorted no se creó y el original estaba vacío, asegurar que exista un archivo vacío
        rm -f data/local/dict/combined_oov_for_g2p_sorted.txt # Limpiar si se creó pero estaba vacío
        touch data/local/dict/combined_oov_for_g2p.txt
    fi
else
    # Si combined_oov_for_g2p.txt no se creó (porque oov_from_data o jerga estaban vacíos), crearlo vacío.
    touch data/local/dict/combined_oov_for_g2p.txt
fi

# 7. Aplicar G2P (Epitran) a las palabras combinadas
if [ -s data/local/dict/combined_oov_for_g2p.txt ]; then
    echo "Aplicando G2P con Epitran a palabras OOV y jerga técnica..."
    # Guardar la salida del G2P en un archivo temporal primero
    cat data/local/dict/combined_oov_for_g2p.txt | python3 "$G2P_PYTHON_SCRIPT" >data/local/dict/lexicon_g2p_output.txt

    echo "Salida del G2P (primeras 10 líneas de lexicon_g2p_output.txt):"
    head -n 10 data/local/dict/lexicon_g2p_output.txt
    echo "Contando líneas en lexicon_g2p_output.txt: $(wc -l <data/local/dict/lexicon_g2p_output.txt)"
    echo "Buscando ABIERTA en lexicon_g2p_output.txt:"
    grep "^ABIERTA " data/local/dict/lexicon_g2p_output.txt || echo "ABIERTA no encontrada en la salida del G2P"

    # Añadir la salida del G2P al lexicon.txt
    cat data/local/dict/lexicon_g2p_output.txt >>data/local/dict/lexicon.txt
    echo "G2P con Epitran completado. Pronunciaciones añadidas a lexicon.txt."
else
    echo "No hay palabras OOV o jerga nuevas para procesar con G2P."
fi

# Guardar una copia de lexicon.txt ANTES de la limpieza final
cp data/local/dict/lexicon.txt data/local/dict/lexicon.txt.before_final_clean

# 8. Añadir el resto del lexicón base si se desea un vocabulario más amplio
# Esto añadiría todas las palabras de BASE_LEXICON_NORMALIZED que no son !SIL, <UNK>
# y que no están ya en lexicon.txt (porque no estaban en vocab_from_data_normalized).
echo "Añadiendo entradas restantes del lexicón base (opcional)..."
awk '
    NR==FNR { seen[$1]=1; next }
    (!($1 in seen) && $1 != "!SIL" && $1 != "<UNK>") { print }
 ' data/local/dict/lexicon.txt "$BASE_LEXICON_NORMALIZED" >>data/local/dict/lexicon.txt

# 9. Limpiar y ordenar lexicon.txt final
echo "Limpiando y ordenando lexicon.txt final..."
awk 'NF > 1' data/local/dict/lexicon.txt | LC_ALL=C sort -u -o data/local/dict/lexicon.txt

# 10. Crear otros archivos del diccionario
echo "Creando archivos de fonemas..."
echo -e "sil\nspn" >data/local/dict/silence_phones.txt
echo "sil" >data/local/dict/optional_silence.txt

awk '{for(i=2;i<=NF;i++) print $i}' data/local/dict/lexicon.txt |
    grep -v -E "^(sil|spn)$" | LC_ALL=C sort -u >data/local/dict/nonsilence_phones.txt

touch data/local/dict/extra_questions.txt # Crear vacío

echo "Preparación del diccionario (data/local/dict/) completada."
echo "Revisa:"
echo "  data/local/dict/lexicon.txt (el lexicón final)"
echo "  data/local/dict/vocab_from_data_normalized.txt (vocabulario de tus datos)"
echo "  data/local/dict/combined_oov_for_g2p.txt (palabras enviadas a G2P)"
echo "  data/local/dict/nonsilence_phones.txt (conjunto de fonemas resultante)"

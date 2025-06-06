# Fine-Tuning de Modelo ASR Vosk para Español con Énfasis en Dominio Técnico

Este proyecto detalla el proceso de fine-tuning de un modelo de Reconocimiento Automático del Habla (ASR) Vosk pre-entrenado para el idioma español. El objetivo principal es mejorar la precisión del modelo base y adaptarlo para transcribir con mayor exactitud audio proveniente de clases y material técnico en los dominios de Redes de Computación y Optimización, considerando también la diversidad de acentos del español.

**Nota:** este proyecto se hizo con ayuda de Gemini 2.5 Pro Preview 05-06
**Nota2:** El próposito y uso de este fine-tuning es para poder implementarse en el proyecto de grado de Ingeneria de Sistemas de Uninorte: http://hdl.handle.net/10584/13381

## Objetivos

*   Adaptar el modelo `vosk-model-small-es-0.42` utilizando corpus de audio en español de OpenSLR.
*   Mejorar el reconocimiento de jerga técnica específica de los dominios de Redes de Computación y Optimización.
*   Obtener un modelo afinado robusto a diferentes acentos del español.
*   Generar un modelo empaquetado que pueda ser utilizado con la API de Vosk para transcripción.

## Estructura del Proyecto (Receta Kaldi)

Este proyecto sigue la estructura típica de una receta de Kaldi, ubicada en el directorio `s5/`.

*   `run.sh`: Script principal que ejecuta todas las etapas del proceso, desde la preparación de datos hasta el entrenamiento y la decodificación.
*   `cmd.sh`: Configuración de los comandos de ejecución para Kaldi (e.g., para ejecución local o en un clúster con GPU).
*   `path.sh`: Configuración de las rutas del entorno de Kaldi.
*   `local/`: Directorio con scripts específicos de esta receta:
    *   `data_prep.sh`: Prepara los datos de audio y transcripciones de los corpus OpenSLR.
    *   `databases.txt`: Archivo de configuración que define los corpus de OpenSLR a utilizar.
    *   `lang_prep.sh`: Prepara el diccionario (lexicón) y los archivos de fonemas.
    *   `lm_prep.sh`: Entrena el modelo de lenguaje n-gram.
    *   `normalize_unicode.py`: Script Python para normalizar texto (transcripciones, jerga).
    *   `preprocess_base_lexicon.py`: Script Python para normalizar el lexicón base.
    *   `g2p_epitran.py`: Script Python que utiliza Epitran para la conversión Grafema-a-Fonema (G2P) de palabras OOV y jerga.
    *   `base_lexicon_openslr.txt`: Un lexicón base en español.
    *   `jerga_tecnica_raw.txt`: Lista de palabras técnicas para añadir al vocabulario.
    *   `chain/`: Scripts adaptados de `vosk-api/training` para el entrenamiento de modelos TDNN de cadena, incluyendo:
        *   `run_ivector_common.sh`: Para la gestión de i-vectors (modificado para usar extractor pre-entrenado).
        *   `run_tdnn.sh`: Para el entrenamiento/fine-tuning del modelo TDNN de cadena (modificado para cargar modelo base y usar hiperparámetros de fine-tuning).
*   `conf/`: Archivos de configuración:
    *   `mfcc.conf`: Configuración para la extracción de características MFCC (proveniente del modelo Vosk base).
*   `exp/`: Directorio donde Kaldi guarda los resultados de los experimentos (modelos, logs, etc.). **Este directorio no se incluye en el control de versiones.**
*   `data/`: Directorio donde Kaldi guarda los datos preparados (train, dev, test), el diccionario y el modelo de lenguaje. **La mayoría de su contenido (excepto `data/local/` y archivos base) no se incluye en el control de versiones.**

## Requisitos Previos

1.  **Kaldi:** Instalado y compilado. `KALDI_ROOT` debe estar configurado correctamente en `path.sh`.
2.  **Python 3:** Con las librerías `vosk`, `sounddevice`, `epitran`.
    ```bash
    pip install vosk sounddevice epitran
    python -m epitran_scripts.download 'spa-Latn' # Para descargar el modelo español de Epitran
    ```
3.  **SRILM:** Instalado dentro de `$KALDI_ROOT/tools/srilm/` (usar `$KALDI_ROOT/tools/install_srilm.sh`).
4.  **Herramientas Estándar de Linux/WSL:** `wget`, `unzip`, `sox`, `awk`, `grep`, `sort`, `perl`, etc.
5.  **(Opcional pero Muy Recomendado) GPU NVIDIA:** Con drivers y CUDA Toolkit configurados (especialmente si se ejecuta en WSL2, asegurar compatibilidad).

## Flujo de Trabajo (`run.sh`)

El script `run.sh` orquesta las siguientes etapas principales. Se pueden ejecutar selectivamente usando las opciones `--stage N --stop-stage M`.

*   **Etapa 0: Preparación de Datos (`local/data_prep.sh`)**
    *   Lee `local/databases.txt` para identificar los corpus de OpenSLR.
    *   Descarga y descomprime los datos.
    *   Normaliza las transcripciones usando `local/normalize_unicode.py`.
    *   Crea los directorios `data/train`, `data/dev`, `data/test` en formato Kaldi.

*   **Etapa 1: Extracción de Características MFCC**
    *   Usa `conf/mfcc.conf` (del modelo Vosk base) para extraer MFCCs.
    *   Calcula estadísticas CMVN.

*   **Etapa 2: Preparación del Lenguaje (Diccionario y Modelo de Lenguaje)**
    *   **Lexicón (`local/lang_prep.sh`):**
        *   Crea un corpus de texto unificado a partir de las transcripciones de entrenamiento/desarrollo.
        *   Extrae un vocabulario de este corpus.
        *   Normaliza y utiliza un lexicón base (`base_lexicon_openslr.txt`) y una lista de jerga técnica (`jerga_tecnica_raw.txt`).
        *   Las palabras fuera del vocabulario base y la jerga se procesan con G2P (`local/g2p_epitran.py`).
        *   Genera `data/local/dict/lexicon.txt` y otros archivos de diccionario.
    *   **`utils/prepare_lang.sh`:** Crea `data/lang/`.
    *   **Modelo de Lenguaje (`local/lm_prep.sh`):**
        *   Entrena un modelo de lenguaje n-gram (trigrama) usando SRILM sobre el corpus de texto unificado.
        *   Convierte el modelo ARPA a `G.fst` y lo guarda en `data/lang_test_tg/`.

*   **Etapa 3: Entrenamiento de Modelos GMM**
    *   Entrena secuencialmente modelos monofónicos (`exp/mono`), trifónicos de deltas (`exp/tri1`), y trifónicos LDA+MLLT (`exp/tri2`, `exp/tri3`).
    *   El objetivo principal es obtener un buen árbol fonético (`exp/tri3/tree`) y alineamientos (`exp/tri3_ali_train`) para el modelo TDNN.

*   **Etapa 4: Fine-Tuning del Modelo TDNN de Cadena**
    *   Utiliza scripts adaptados de `vosk-api/training` (`local/chain/run_ivector_common.sh`, `local/chain/run_tdnn.sh`).
    *   **i-vectors (`run_ivector_common.sh`):**
        *   Usa el extractor de i-vectors (`final.ie`) del modelo Vosk base (`exp/vosk_model_base/ivector/`).
        *   Extrae i-vectors para los datos de entrenamiento (`data/train`).
    *   **TDNN (`run_tdnn.sh`):**
        *   Crea la topología de lenguaje de cadena y el árbol de cadena.
        *   Genera lattices a partir de los alineamientos GMM.
        *   Define la arquitectura de red (usando `network.xconfig` de `vosk-api/training`).
        *   **Inicializa el entrenamiento (fine-tuning):** Transfiere los pesos del `final.mdl` del modelo Vosk base (`exp/vosk_model_base/am/final.mdl`) al modelo inicial (`0.mdl`) del TDNN.
        *   Entrena el TDNN por un número reducido de épocas con tasas de aprendizaje bajas.
        *   El modelo afinado se guarda en un subdirectorio de `exp/chain_vosk_ft/`.

*   **Etapa 5: Decodificación y Evaluación**
    *   Crea el grafo de decodificación HCLG (`utils/mkgraph.sh`) usando el TDNN afinado y el `G.fst`.
    *   Extrae i-vectors para los conjuntos `dev` y `test`.
    *   Decodifica los conjuntos `dev` y `test` usando `steps/nnet3/decode.sh`.
    *   Calcula el Word Error Rate (WER).

## Ejecución

1.  **Configura `path.sh`** para que `KALDI_ROOT` apunte a tu instalación de Kaldi.
2.  **Configura `cmd.sh`** para tu entorno de ejecución (e.g., `run.pl` para local, ajusta `--gpu 1` si tienes GPU).
3.  **Prepara tus archivos base:**
    *   Coloca tu lexicón base en `local/base_lexicon_openslr.txt`.
    *   Coloca tu lista de jerga en `local/jerga_tecnica_raw.txt`.
    *   Copia los archivos del modelo `vosk-model-small-es-0.42` a `../exp/vosk_model_base/` (un nivel arriba de `s5/`) con la estructura:
        *   `../exp/vosk_model_base/am/final.mdl`
        *   `../exp/vosk_model_base/ivector/final.ie` (y otros archivos de `ivector/` como `online_cmvn.conf`, `splice.conf`, `global_cmvn.stats`, `final.dubm`)
        *   Asegúrate de que `s5/conf/mfcc.conf` sea el del modelo Vosk.
4.  **Ejecuta el script principal desde el directorio `s5/`:**
    ```bash
    bash run.sh
    ```
    O para ejecutar etapas específicas:
    ```bash
    bash run.sh --stage <numero_etapa_inicio> --stop-stage <numero_etapa_fin>
    ```
    Por ejemplo, para ejecutar solo la preparación de datos y MFCC:
    ```bash
    bash run.sh --stage 0 --stop-stage 1
    ```

## Empaquetado del Modelo para Vosk API

Después de un entrenamiento exitoso, los componentes necesarios (modelo acústico, grafo, configuración de i-vector, etc.) se pueden empaquetar en una estructura de directorio similar a los modelos Vosk oficiales para ser utilizados con la API de Vosk. Ver el script `empaquetar_modelo.sh`

## Flujo de trabajo resumido
<img src="/home/draken/projects/kaldi/uml.png" width="250"/>

## Resultados:

*   **Para el conjunto de Desarrollo (`dev`):**
    *   El mejor WER fue: **3.50%**
    *   Esto corresponde a la línea: `%WER 3.50 [ 147 / 4197, 7 ins, 40 del, 100 sub ] exp/chain_vosk_ft/tdnn_1a/decode_dev_graph_tg/wer_8`

*   **Para el conjunto de Prueba (`test`):**
    *   El mejor WER fue: **1.62%**
    *   Esto corresponde a la línea: `%WER 1.62 [ 91 / 5607, 9 ins, 36 del, 46 sub ] exp/chain_vosk_ft/tdnn_1a/decode_test_graph_tg/wer_11`

**Los números dentro de los corchetes `[ ... ]` se interpretan así:**

`[ <errores_totales> / <palabras_totales_referencia>, <inserciones> ins, <eliminaciones> del, <sustituciones> sub ]`

Entonces:

*   **Para `dev` (`wer_8`):**
    *   `147`: Número total de errores.
    *   `4197`: Número total de palabras en las transcripciones de referencia del conjunto de desarrollo.
    *   `7 ins`: 7 palabras fueron insertadas incorrectamente por el sistema.
    *   `40 del`: 40 palabras de la referencia fueron omitidas (eliminadas) por el sistema.
    *   `100 sub`: 100 palabras de la referencia fueron sustituidas por otras incorrectas por el sistema.
    *   (7 + 40 + 100 = 147 errores)

*   **Para `test` (`wer_11`):**
    *   `91`: Número total de errores.
    *   `5607`: Número total de palabras en las transcripciones de referencia del conjunto de prueba.
    *   `9 ins`: 9 palabras fueron insertadas incorrectamente.
    *   `36 del`: 36 palabras de la referencia fueron omitidas.
    *   `46 sub`: 46 palabras de la referencia fueron sustituidas.
    *   (9 + 36 + 46 = 91 errores)

* Aun así, debido a las limitaciones del poder computacional se demostra aun bajo rendiemnto para las transcripciones. Se motiva a continuar mejorando este proyecto y corrigiendo los posibles errores que se encuentre allí.
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import sys
try:
    from normalize_unicode import normalize_word_for_kaldi_lexicon
except ImportError:
    import os
    sys.path.append(os.path.dirname(os.path.abspath(__file__)))
    from normalize_unicode import normalize_word_for_kaldi_lexicon


if len(sys.argv) != 2:
    sys.stderr.write(f"Uso: python3 {sys.argv[0]} <archivo_lexicon_base_input>\n")
    sys.exit(1)

input_lex_file = sys.argv[1]

try:
    with open(input_lex_file, 'r', encoding='utf-8') as f_in:
        for line_num, line in enumerate(f_in, 1):
            line = line.strip()
            if not line or line.startswith('#'): # Ignorar vacías o comentarios
                continue
            
            parts = line.split('\t', 1) 
            if len(parts) == 2:
                word_original, pron = parts
                # Normaliza la palabra original usando la función consistente
                normalized_word_key = normalize_word_for_kaldi_lexicon(word_original) 
                
                if normalized_word_key and normalized_word_key != "UNK_SYMBOL_NORM": # Evitar escribir si la normalización falló
                    # Imprime: PALABRA_NORMALIZADA <espacio> p r o n u n c i a c i o n
                    sys.stdout.write(f"{normalized_word_key} {pron.strip()}\n")
            else:
                sys.stderr.write(f"Advertencia (preprocess_base_lexicon): Línea {line_num} en {input_lex_file} no tiene formato palabra<TAB>pron: '{line}'\n")
except FileNotFoundError:
    sys.stderr.write(f"Error (preprocess_base_lexicon): Archivo de entrada {input_lex_file} no encontrado.\n")
    sys.exit(1)
except Exception as e:
    sys.stderr.write(f"Error inesperado en preprocess_base_lexicon.py: {e}\n")
    sys.exit(1)
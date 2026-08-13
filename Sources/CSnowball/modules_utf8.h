/* libstemmer/modules_utf8.h: List of stemming modules.
 *
 * Trimmed from the libstemmer_c 2.2.0 distribution to the languages Clabar
 * ships (see stem_UTF_8_*.c alongside); include paths flattened for SPM.
 * To add a language: vendor its stem_UTF_8_<lang>.c/.h and add a row below.
 */

#include "stem_UTF_8_english.h"
#include "stem_UTF_8_french.h"
#include "stem_UTF_8_german.h"
#include "stem_UTF_8_portuguese.h"
#include "stem_UTF_8_russian.h"
#include "stem_UTF_8_spanish.h"

typedef enum {
  ENC_UNKNOWN=0,
  ENC_UTF_8
} stemmer_encoding_t;

struct stemmer_encoding {
  const char * name;
  stemmer_encoding_t enc;
};
static const struct stemmer_encoding encodings[] = {
  {"UTF_8", ENC_UTF_8},
  {0,ENC_UNKNOWN}
};

struct stemmer_modules {
  const char * name;
  stemmer_encoding_t enc;
  struct SN_env * (*create)(void);
  void (*close)(struct SN_env *);
  int (*stem)(struct SN_env *);
};
static const struct stemmer_modules modules[] = {
  {"de", ENC_UTF_8, german_UTF_8_create_env, german_UTF_8_close_env, german_UTF_8_stem},
  {"en", ENC_UTF_8, english_UTF_8_create_env, english_UTF_8_close_env, english_UTF_8_stem},
  {"es", ENC_UTF_8, spanish_UTF_8_create_env, spanish_UTF_8_close_env, spanish_UTF_8_stem},
  {"fr", ENC_UTF_8, french_UTF_8_create_env, french_UTF_8_close_env, french_UTF_8_stem},
  {"pt", ENC_UTF_8, portuguese_UTF_8_create_env, portuguese_UTF_8_close_env, portuguese_UTF_8_stem},
  {"ru", ENC_UTF_8, russian_UTF_8_create_env, russian_UTF_8_close_env, russian_UTF_8_stem},
  {0,ENC_UNKNOWN,0,0,0}
};
static const char * algorithm_names[] = {
  "de", "en", "es", "fr", "pt", "ru",
  0
};

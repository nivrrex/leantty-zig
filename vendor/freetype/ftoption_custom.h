/* vendored FreeType 配置：关闭需要外部库的压缩/整形支持（zlib/bzip2/png/brotli/harfbuzz），
 * 只保留字体解析与本工程需要的光栅器。用 -DFT_CONFIG_OPTIONS_H='"ftoption_custom.h"' 启用。 */
#include <freetype/config/ftoption.h>
/* 保留 FT_CONFIG_OPTION_USE_ZLIB：彩色 emoji（CBDT/PNG）必须解压；
 * FreeType 自带一份精简 zlib（src/gzip/*.c），不引入外部依赖。 */
#undef FT_CONFIG_OPTION_USE_BZIP2
#undef FT_CONFIG_OPTION_USE_PNG
#undef FT_CONFIG_OPTION_USE_BROTLI
#undef FT_CONFIG_OPTION_USE_HARFBUZZ

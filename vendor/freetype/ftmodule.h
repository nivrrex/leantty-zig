/* 精简模块表（vendored FreeType 用）：只保留 leantty 需要的驱动。
 * 用法：-DFT_CONFIG_MODULES_H='<ftmodule.h>'（构建脚本已设置）。 */
FT_USE_MODULE( FT_Module_Class, autofit_module_class )
FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )
/* sfnt 是 TrueType/OpenType 的表服务模块，缺了会让 FT_New_Face 返回 Missing_Module(0x0B)。 */
FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
FT_USE_MODULE( FT_Module_Class, psaux_module_class )
FT_USE_MODULE( FT_Module_Class, psnames_module_class )
FT_USE_MODULE( FT_Module_Class, pshinter_module_class )
FT_USE_MODULE( FT_Renderer_Class, ft_raster1_renderer_class )
FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
FT_USE_MODULE( FT_Renderer_Class, ft_sdf_renderer_class )

name = "附近自动烹饪（保鲜优先）"
description = [[在原版锅界面填写烹饪数量，再点击原版“烹饪”。
手动放入的食材就是配方，后续自动按同样配比续做。
烹饪中右键锅可调整剩余数量或取消后续配方。
自动从附近箱子、冰柜、地窖和地面取料；成品优先存入保鲜容器。
食材与料理带飞入飞出效果。支持标准 stewer 锅与 container 储藏模组。]]
author = "wanzi"
version = "1.0.2"
forcemanifest = false
api_version = 10
dst_compatible = true
dont_starve_compatible = false
reign_of_giants_compatible = false
shipwrecked_compatible = false
client_only_mod = false
all_clients_require_mod = true
server_only_mod = false
server_filter_tags = { "自动烹饪", "保鲜" }

configuration_options = {
    { name = "SEARCH_RADIUS", label = "取料和存放范围", default = 12,
      options = {
          { description = "4（约1块地皮）", data = 4 },
          { description = "8（约2块地皮）", data = 8 },
          { description = "12（约3块地皮）", data = 12 },
          { description = "16（约4块地皮）", data = 16 },
          { description = "24（约6块地皮）", data = 24 },
      } },
    { name = "GROUND_INGREDIENTS", label = "取用地面食材", default = true,
      options = { { description = "开启（储藏优先）", data = true }, { description = "关闭", data = false } } },
    { name = "CHECK_INTERVAL", label = "检查间隔", default = 1,
      options = { { description = "0.5秒", data = .5 }, { description = "1秒", data = 1 }, { description = "2秒", data = 2 } } },
    { name = "TRANSFER_FX", label = "食材飞行动画", default = true,
      options = { { description = "开启", data = true }, { description = "关闭", data = false } } },
}

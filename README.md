# TCP 连接数保护面板

适用于 Alpine Linux / OpenRC 的代理 VPS，用来把系统 TCP 总数控制在服务商关机阈值以下。

脚本功能：

- 按输入的 TCP 关机上限自动计算保护阈值。
- 限制代理端口的新 TCP 入站连接。
- 快速清理 `SYN-RECV`、`SYN-SENT`、`TIME-WAIT`、`CLOSE-WAIT` 等残留状态。
- 临界时可清理已建立的代理 TCP，避免 VPS 触发关机。
- 不停止 `xboard-node` 或你的代理服务。
- 带中文交互菜单。

## 一键运行

在 VPS 上执行：

```sh
wget -O /root/tcp-limit-panel.sh https://raw.githubusercontent.com/ya-zhe/tcpcodex/main/tcp-limit-panel.sh && chmod +x /root/tcp-limit-panel.sh && /root/tcp-limit-panel.sh
```

如果 VPS 没有 `wget`：

```sh
apk add --no-cache wget
```

## 推荐填写

如果服务商 TCP 上限是 `480`：

```text
服务商 TCP 关机上限 [480]: 480
代理 TCP/UDP 端口，多个端口用英文逗号分隔 [25001,25002]: 25001,25002
服务名称，仅用于查看状态，脚本不会停止它 [xboard-node]:
达到临界线时是否踢掉已建立的代理 TCP？ [y]: y
是否为这些端口额外添加放行规则？ [n]: n
```

如果服务商 TCP 上限是 `150`，就填 `150`。脚本会自动把阈值调得更保守。

## 菜单

```text
1) 安装或更新保护
2) 查看状态
3) 手动清理代理 TCP 状态
4) 卸载脚本管理的保护
0) 退出
```

## 常用命令

查看 TCP 总数：

```sh
ss -Htan | wc -l
```

查看 TCP 状态：

```sh
ss -Htan | awk '{s[$1]++} END {for (k in s) print k, s[k]}'
```

查看保护日志：

```sh
tail -f /var/log/tcp-guard.log
```

手动清理代理端口上的半开和残留 TCP：

```sh
/usr/local/sbin/tcp-trim-now.sh
```

手动清理并踢掉已建立的代理 TCP：

```sh
/usr/local/sbin/tcp-trim-now.sh --established
```

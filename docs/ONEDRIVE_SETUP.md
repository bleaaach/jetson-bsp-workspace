# OneDrive 授权配置说明

本文件记录 BSP 工作流 Web 端通过 rclone 上传固件到 OneDrive 所需配置。

## 现状

Web 端固件同步功能位于 `web/app/firmware_sync.py`，依赖：

- 已安装 `rclone`
- rclone 已配置 OneDrive remote（默认名 `onedrive`）

当前 rclone 已安装，但 OneDrive remote 尚未配置。

## 组织 OneDrive 配置步骤

由于 Microsoft 365 企业租户默认禁止第三方 OAuth 应用，需要租户管理员先创建一个 Azure 应用注册并授予管理员同意。

### 1. 创建 Azure 应用注册

由租户管理员登录 https://portal.azure.com 执行：

1. 进入 **Microsoft Entra ID** → **App registrations** → **New registration**
2. 填写：
   - **Name**: `rclone-bsp-workspace`
   - **Supported account types**: `Accounts in this organizational directory only`
   - **Redirect URI**: 类型选 `Web`，值填 `http://localhost:53682/`
3. 点击 **Register**
4. 记录 **Application (client) ID**

### 2. 添加 API 权限

进入应用 → **API permissions** → **Add a permission**：

- 选择 **Microsoft Graph**
- 选择 **Delegated permissions**
- 添加以下权限：
  - `Files.ReadWrite` — 读写 OneDrive 文件
  - `User.Read` — 读取用户配置文件
  - `offline_access` — 保持刷新 token

### 3. 创建 Client Secret

进入应用 → **Certificates & secrets** → **New client secret**：

- 填写描述，选择过期时间
- 创建后复制 **Value** 字段（只显示一次）

### 4. 授予管理员同意

在 **API permissions** 页面，点击 **Grant admin consent for [租户名]**。

### 5. 配置 rclone

获取到 **Application (client) ID** 和 **Client secret value** 后，在工作区执行：

```bash
./tools/setup-onedrive-remote.sh <client_id> <client_secret>
```

按提示完成浏览器授权。

### 6. 验证

```bash
rclone listremotes
rclone lsd onedrive:
```

`rclone listremotes` 输出包含 `onedrive:` 即表示配置成功。

## Web 端状态

配置完成后，Web 端固件同步页面会自动检测 OneDrive remote 状态：

- 绿色：OneDrive 远程已就绪
- 红色：rclone 未找到 OneDrive remote

## 故障排查

### 管理员看不到审批请求

- 使用上述自定义 Azure 应用注册，不要使用 rclone 内置 client ID
- 确认管理员在 **API permissions** 页面点击了 **Grant admin consent**

### Web 端提示 "未找到 rclone"

- 确认 rclone 已安装：

```bash
rclone version
```

### 上传失败

- 确认 NAS/SMB 配置正确
- 查看 rclone 错误日志
- 确认 OneDrive 路径有写入权限

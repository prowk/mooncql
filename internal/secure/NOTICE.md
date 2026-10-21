# TLS 适配层来源

本目录基于 moonbitlang/async 0.22.3 的 src/tls，原作者 International Digital Economy Academy，遵循 Apache-2.0。原始文件的版权及许可说明予以保留；UPSTREAM.json 固定原始字节的 SHA-256。

本项目改动：隔离 FFI 符号；为 OpenSSL 增加客户端 PEM 证书及私钥加载，为 Windows Schannel 增加按显式指纹选取的客户端证书存储凭据；限制驱动入口始终进行证书与服务端名称验证。TLS 密码学及证书验证由成熟系统库完成。原适配层保留其原始注释，新改动注释使用中文。

该副本用于补足当前上游客户端凭据接口。传输层改用公共 IO 接口及独立缓冲区，移除对运行时私有包和缓冲区布局的依赖；所需的小型内存及系统字符串辅助实现位于 support。升级时须核对差异并重新执行跨平台 TLS 矩阵。

Windows 自定义 CA 验证将远端证书存储加入链构建，以使用服务端发送的中间证书；信任锚仍仅来自配置的根 CA。

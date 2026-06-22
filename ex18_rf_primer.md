# ex18 射频知识入门

> 本文档梳理 ex18 SFCW GPR 模型中涉及的射频（RF）概念，帮助理解从数字基带 → RF 前端 → 天线 → 通道 → 接收解调的全链路。

---

## 1. SFCW 体制（Stepped-Frequency Continuous Wave）

SFCW 是 ex18 的核心信号体制，区别于脉冲体制：

| 体制 | 发射波形 | 时域 | 频域 | 可探测距离 |
|------|---------|------|------|-----------|
| **脉冲 GPR** | 窄脉冲（如高斯脉冲） | 短时宽 | 宽频谱（一次打出整个带宽） | 受峰值功率限制 |
| **SFCW GPR** | 按顺序发射 N 个单频 CW 信号 | 宽时宽（每个频点持续 τ） | 单频点依次扫描，合成宽带宽 | 峰值功率低但探测深度大 |

### ex18 频率计划（`setup_ex18_sfw.m:57-61`）
```
f_start_hz =  20 MHz
f_stop_hz  = 270 MHz
df_hz      = 0.5 MHz
N_points   = (270-20)/0.5 + 1 = 501
```

单个频点数学形式：
```
s_i(t) = C_i · cos(2π·f_i·t + θ_i)
    f_i = f_0 + i·Δf,  i = 0, 1, ..., N-1
```

### SFCW 关键性能指标

| 指标 | 公式 | ex18 值 | 含义 |
|------|------|---------|------|
| 最大无模糊距离 | R_unamb = c₀ / (2·√εᵣ·Δf) | ~31.6 m (土壤中) | 超过此距离的回波会折叠到短距离 |
| 距离分辨率 | ΔR = c₀ / (2·√εᵣ·BW) | ~0.20 m (土壤中) | 相距小于此值的两个目标无法分辨 |
| 等效脉冲宽度 | τ_eff ≈ 1 / BW | 4 ns | IFFT 后在时域等效于一个 4 ns 宽脉冲 |

---

## 2. 射频前端链路

ex18 的 RF 前端由 RF Blockset 搭建，信号路径如下：

```
       +--[直通]-- RF_Attn -- RF_VGA -- RF_PA -- RF_Out -- TX_Radiator --+
       |                 (-10 dB)    (0 dB)    (10 dB)                    |
DAC ---+-- RF_In --+                                                      +--> GPR_Channel (FIR)
                   |                                                      |
                   +--[耦合]-- RF_Tap_Out (LO 支路)                       |
```

### 2.1 各模块说明

#### RF_In (`simrfV2util1/Inport`)
- 将 Simulink 数值信号转换为 RF Blockset 物理域（电压波）信号
- 源阻抗 Zₛ = 50 Ω（`build_ex18_sfw_top.m:97`）
- 载频 = 0 Hz（baseband input at 0 Hz carrier）
- **用途**：把基带 SFW burst 送入 RF 网络

#### RF_Attn（Attenuator，`simrfV2elements/Attenuator`）
- 衰减量：10 dB（`cfg.front.attn_db`）
- 输入/输出阻抗：50 Ω
- 添加噪声
- **RF 用途**：控制进入后级放大器的信号功率，防止 PA 饱和

#### RF_VGA（Variable Gain Amplifier，`simrfV2elements/Amplifier`）
- 增益：0 dB（默认）
- 噪声系数：4 dB（`cfg.front.vga_nf_db`）
- **RF 用途**：可调增益级，本项目中用于平衡链路总增益

#### RF_PA（Power Amplifier，`simrfV2elements/Amplifier`）
- 增益：10 dB（`cfg.front.pa_gain_db`）
- 噪声系数：5 dB（`cfg.front.pa_nf_db`）
- **RF 用途**：末级功率放大器，驱动天线

#### RF_Coupler（S-parameters Coupler，`simrfV2elements/S-parameters`）
- 4 端口 S-参数网络（`build_ex18_sfw_top.m:123-131`）
  - Port 1 = 输入（RF_In 方向）
  - Port 2 = 直通（→ Attn）
  - Port 3 = 耦合（→ RF_Tap_Out，作为 LO 参考）
  - Port 4 = 隔离（→ 50 Ω 端接）
- 耦合度：6 dB（`cfg.front.cpl_db`）
- 插入损耗：3 dB（`cfg.front.cpl_insertion_loss_db`）
- **RF 用途**：从主路分离一小部分信号作为参考（loopback），用于后续的均衡（equalization）

#### RF_Out（`simrfV2util1/Outport`）
- 将 RF Blockset 物理域信号转回 Simulink 数值信号
- 负载阻抗 Zₗ = 50 Ω（`build_ex18_sfw_top.m:154`）
- **输出信号为实数标量**（电压值）

### 2.2 级联增益和噪声分析（Friis 公式）

Friis 级联噪声公式：
```
F_total = F_1 + (F_2 - 1)/G_1 + (F_3 - 1)/(G_1·G_2) + ...
```

ex18 链路（按默认值）：

| 级 | 模块 | 增益 G (线性) | 噪声系数 NF (dB) | 累积 NF (dB) |
|----|------|--------------|-----------------|-------------|
| 1 | RF_Attn | 0.316 (-10 dB) | 10 dB (= 衰减量) | 10.0 dB |
| 2 | RF_VGA | 1.0 (0 dB) | 4 dB | 14.0 dB |
| 3 | RF_PA | 10.0 (10 dB) | 5 dB | ~14.0 dB |

由于第一级衰减器的增益 < 1，它对总噪声系数的贡献被放大（衰减器前的噪声源直接被衰减，但衰减器本身的热噪声不被衰减），导致系统噪声系数约为 14 dB。

---

## 3. 混频器与变频

ex18 有两级混频：上变频（up-conversion）和下变频（down-conversion）。

### 3.1 上变频: Tap Mixer（`setup_ex18_sfw.m:169-193`）

```
SFW In (20-270 MHz) × LO (200 MHz) → 上边带 (220-370 MHz) + 下边带 (30-180 MHz)
                                                     ↓
                                              Tap_Up_BPF
                                             保留上边带 210-380 MHz
```

- 本振频率：LO = 200 MHz，幅度 ×2（以补偿实数混频的 1/2 倍）
- 混频原理：
  ```
  cos(2π·f_s·t) × cos(2π·f_LO·t)
  = ½·cos(2π·(f_LO - f_s)·t) + ½·cos(2π·(f_LO + f_s)·t)
  ```
  - 下边带：200 - (20~270) = 30~180 MHz（被 BPF 抑制）
  - 上边带：200 + (20~270) = 220~370 MHz（保留）
- BPF 通带：210-380 MHz（含 10 MHz 保护带）
- FIR 阶数：8192 阶

**RF 意义**：将基带 SFCW 信号搬移到较高的中频/射频频段，避开直流和 1/f 噪声区域，同时适配后级天线频带。

### 3.2 下变频: Down Mixer（`setup_ex18_sfw.m:198-206`）

```
RX_Antenna (20-270 MHz) × Tap_Up_Out (220-370 MHz) → 差频 (≈200 MHz) + 和频 (>400 MHz)
                                                      ↓
                                               RX_Down_IF_BPF
                                               保留 190-210 MHz IF
```

- 关键思想：RX 端接收到的原始 SFW 信号与 LO 参考信号（来自耦合器的副本）做第二次混频
  - 差频项：(LO + f_s) - f_s = LO = 200 MHz（对所有 f_s 恒定！）
  - 和频项：(LO + f_s) + f_s = LO + 2f_s（被 BPF 抑制）
- IF 中心频率：200 MHz
- IF 半带宽：10 MHz（最终通带 190-210 MHz）
- BPF 阶数：8192 阶

**RF 意义**：利用同一个 LO 对 RX 信号做"去斜频（deramp）"，将所有 SFCW 频点统一转换为固定频率的 IF 信号，大幅降低后续 ADC 采样率要求。

### 3.3 I/Q 解调（`setup_ex18_sfw.m:208-218`）

```
IF 200 MHz → LP_BPF (10 MHz cutoff) → 乘以 LO_200MHz
                                       ├→ I: cos(ω_IF·t) → LPF → I(t)
                                       └→ Q: sin(ω_IF·t) → LPF → Q(t)
```

- I 路本振：0° 相位，幅度 ×2
- Q 路本振：-90° 相位，幅度 ×2
- LPF 截止：10 MHz
- FIR 阶数：1024

**RF 意义**：I/Q 解调从 IF 信号中提取完整的复基带包络，保留幅度和相位信息。GPR 目标探测依赖相位信息（双程延迟），因此必须保留 I/Q。

---

## 4. 50 Ω 阻抗系统

ex18 的 RF 网络统一使用 **50 Ω** 参考阻抗（`cfg.front.z0_ohm`）。

- **为什么是 50 Ω？**：射频工程标准的折中选择——兼顾最小损耗（77 Ω，空气介质）和最大功率容量（30 Ω）。50 Ω 是这两者的几何平均 √(30×77) ≈ 48 Ω，取整为 50 Ω。
- ex18 中 50 Ω 体现在：
  - RF_In 的源阻抗 Zₛ
  - RF_Out 的负载阻抗 Zₗ
  - 所有 Attenuator、Amplifier 的 Zin/Zout
  - 耦合器的 S-参数参考阻抗
  - 隔离端接电阻（Iso_Term）

---

## 5. 天线基础

### 5.1 当前天线实现

ex18 使用 **Phased Array System Toolbox** 的天线（`build_ex18_sfw_top.m:182-225`）：

```matlab
% TX: phased.Radiator + phased.IsotropicAntennaElement
% RX: phased.Collector + phased.IsotropicAntennaElement
```

- 各向同性天线（在所有方向增益相同）
- 工作频率 = mean(20MHz, 270MHz) ≈ 145 MHz
- 因为是 Isotropic + 垂直入射，**增益 = 1，相移 = 0**
- 天线在射频链路中实际表现为**直通**，所有物理效应都在 GPR_Channel FIR 中建模

### 5.2 RF Blockset Antenna 模块（可选）

如之前的讨论，RF Blockset 自 R2020b 起提供 **Antenna** 模块（位于 `simrfV2/Circuit Envelope/Elements`），可以：

| 模式 | 功能 |
|------|------|
| Isotropic radiator | 指定增益 (dBi) + 复阻抗 (Ω) |
| Antenna Designer | 调用 Antenna Toolbox 设计偶极子、贴片等 |
| Antenna object | 从工作区导入 `antenna` / `antennaArray` 对象 |

该模块建模了：
- **天线阻抗** → 阻抗失配引起的功率反射
- **方向图增益** → 离开/到达角相关的增益变化
- **极化** → θ/φ 双极化分量
- **热噪声** → 根据阻抗实部产生 Johnson-Nyquist 噪声

### 5.3 天线基本参数

| 参数 | 含义 | ex18 等效值 |
|------|------|-----------|
| 天线高度 | Tx/Rx 离地高度 | 1.0 m |
| Tx-Rx 间距 | 发射-接收天线的水平距离 | 0.5 m |
| 等效各向同性辐射功率 (EIRP) | P_Tx × G_ant | 程序中取 G_ant=1，EIRP = P_Tx |
| 自由空间路径损耗 | (λ/4πR)² | GPR 通道另有土壤损耗 |

---

## 6. GPR 传播通道

### 6.1 直耦（Direct Coupling）

Tx 天线发射的信号**直接耦合**到 Rx 天线，不经过地表或目标。

```
cfg.gpr.direct_coupling_amplitude = 0.10    % 直耦幅度（相对）
cfg.gpr.direct_extra_delay_s = 1.5e-9      % 固定附加延迟（天线内部+馈线）
direct_distance = hypot(TxRx_spacing, 0.01) % ≈ 0.5 m
total_delay = 1.5 ns + 0.5 m / c₀ ≈ 3.17 ns
```

直耦是 GPR 中的**强干扰**，幅度通常远大于目标回波。ex18_ascan_no_bg 保留直耦。

### 6.2 地表反射（Surface Reflection）

信号经空气传播到地表，反射后回到 Rx。

```
surface_path = hypot(TxRx_spacing, 2 × antenna_height)
              = hypot(0.5, 2×1.0) ≈ 2.06 m
delay = 2.06 / c₀ ≈ 6.88 ns
```

- 传播介质：空气（c₀）
- 反射系数由空气-土壤界面 Fresnel 公式决定：
  ```
  Γ_surface = (η_soil - η₀) / (η_soil + η₀)
  ```
  其中 η₀ = √(μ₀/ε₀) ≈ 377 Ω，η_soil = √(jωμ₀ / (σ + jωε_soil))

### 6.3 土壤传播

```
εᵣ = 9.0, σ = 0.012 S/m
v_soil = c₀ / √εᵣ = 1×10⁸ m/s ≈ 0.1 m/ns
```

**传播常数**（`build_bscan_state`）：
```
γ = √(jωμ₀ · (σ + jωεᵣε₀))
  = α + jβ
```
其中：
- α = 衰减常数 (Np/m)——信号随距离指数衰减
- β = 相位常数 (rad/m)——决定波速和波长

有损土壤的衰减随频率升高而增大，这是 SFCW GPR 的固有限制：低频可穿透更深但分辨率低，高频分辨率高但穿透浅。

### 6.4 目标反射

管道目标建模（`ex18_make_bscan.m:174-194`）：

```
path_m = max(d_tx - radius, 0) + max(d_rx - radius, 0)  % 反射发生在管道表面
ang_gain = (cosθ_tx · cosθ_rx)^taper                      % 角度增益
spread = 1 / (1 + spreading_factor × path/2)²             % 几何扩散
prop = exp(-γ_soil × path_m)                               % 土壤传播损耗
```

- 复反射系数 1.40×exp(j×0.35)（目标1 管道参数）
- 管道半径 0.055 m

---

## 7. 背景扣除与均衡

### 7.1 背景扣除（Background Subtraction）

GPR B-scan 处理中的关键步骤：

```
H_bg(f) = H_direct(f) + H_surface(f) + H_clutter(f)
H_target(f) = H_total(f) - α × H_bg(f)

其中 α 是复比例系数，通过最小二乘估计：
α = <H_bg, H_total> / <H_bg, H_bg>
```

扣除后只剩目标回波，这是 ex18_make_bscan 的默认操作（`BackgroundMode='model'`）。

### 7.2 Loopback 均衡（Equalization）

耦合器分离出的参考信号用于估计发射链路的幅相响应（非理想性），然后从接收信号中消除这些非理想性。

```
H_corrected(f) = H_rx(f) / H_loopback(f)
```

这是 SFCW 系统的标准校准方法，补偿：
- 放大器幅相频率响应
- 电缆/连接器群时延
- 温度漂移

---

## 8. 时域与频域的关系

### SFCW → IFFT → A-scan

```
H(f), f = 20, 20.5, ..., 270 MHz (501 点)
 │
 ├── 前端延迟补偿: H_corr = H × exp(j2πf·τ_corr), τ_corr = 3.8 ns
 ├── 加窗: H_W = H_corr × w(f), w = hann(501)
 ├── 补零到 NFFT = 4096
 ├── IFFT → h(t) 复数时域信号
 │
 └── A-scan = |h(t)| (或 dB 显示)
```

| 频域参数 | → 时域对应 |
|---------|-----------|
| Δf = 0.5 MHz | 最大无模糊时间 T_max = 1/Δf = 2000 ns |
| BW = 250 MHz | 时间分辨率 Δt ≈ 1/BW = 4 ns |
| NFFT = 4096 | 时间采样间隔 Δt_s = 1/(NFFT×Δf) ≈ 0.488 ns |

---

## 9. 关键 RF 指标速查表

| 概念 | 公式 | 说明 |
|------|------|------|
| 功率 dBm | P_dBm = 10·log_10(P_W / 0.001) | 功率相对于 1 mW 的分贝表示 |
| 功率 dB | P_dB = 10·log_10(P_out/P_in) | 增益/损耗的比例分贝表示 |
| 电压 dB | V_dB = 20·log_10(V_out/V_in) | 电压增益的分贝表示 |
| 噪声系数 NF | NF = SNR_in_dB - SNR_out_dB | 系统引入的额外噪声 |
| 级联 NF | F = F₁ + (F₂-1)/G₁ + ... | 多级放大器总噪声系数 |
| 1 dB 压缩点 | P_1dB | 增益下降 1 dB 时的输入/输出功率 |
| IP3 | 三阶截断点 | 基频与三阶交调的功率相等点 |
| 阻抗匹配 | Γ = (Z_L - Z₀)/(Z_L + Z₀) | 反射系数，Γ=0 为完美匹配 |
| VSWR | VSWR = (1+\|Γ\|)/(1-\|Γ\|) | 电压驻波比，理想值 = 1 |

---

## 10. 相关工具箱

| 工具箱 | 在 ex18 中的角色 |
|--------|----------------|
| **RF Blockset (SimRF)** | RF 前端链路：Inport/Outport、衰减器、放大器、耦合器、Configuration |
| **DSP System Toolbox** | FIR 滤波器设计（`firpm`、`designfilt`）、频谱分析 |
| **Phased Array System Toolbox** | 天线元素（Radiator/Collector）、方向图 |
| **Communications Toolbox** | 自由空间路径损耗（可选） |
| **Signal Processing Toolbox** | 窗函数（hann）、IFFT、滤波 |
| **Antenna Toolbox** | 天线设计（可选，若使用 Antenna 模块非 isotropic 模式） |

---

## 参考代码位置

| 内容 | 文件 | 关键行 |
|------|------|--------|
| 频率计划 | `setup_ex18_sfw.m` | 57-61 |
| RF 前端参数 | `setup_ex18_sfw.m` | 89-110 |
| GPR 几何参数 | `setup_ex18_sfw.m` | 112-167 |
| 上变频 | `setup_ex18_sfw.m` | 169-193 |
| 下变频/IF | `setup_ex18_sfw.m` | 198-206 |
| I/Q 解调 | `setup_ex18_sfw.m` | 208-218 |
| GPR 通道 FIR | `setup_ex18_sfw.m` | 270-299 |
| 构建 RF 网络 | `build_ex18_sfw_top.m` | 89-147 |
| 天线块 | `build_ex18_sfw_top.m` | 182-225 |
| 信号连线 | `build_ex18_sfw_top.m` | 346-396 |
| B-scan 通道模型 | `ex18_make_bscan.m` | 144-208 |
| 土壤电磁参数 | `ex18_make_bscan.m` | 116-142 |

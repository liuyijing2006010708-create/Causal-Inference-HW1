# =====================================================================
# 课程项目：《机器学习与因果推断》大作业 - 蒙特卡洛模拟核心引擎
# 生成资产：summary_table (Excel/控制台) | density_plot.png | common_support_plot.png
# 运行环境：R 4.0+ 推荐
# =====================================================================

# ---------------------------------------------------------------------
# 1. 载入必需包（确保你已提前 install.packages 对应的包）
# ---------------------------------------------------------------------
library(tidyverse)
library(MatchIt)
library(fixest)

# ---------------------------------------------------------------------
# 2. 定义单次模拟的“工厂函数” (核心因果数据生成与多模型估计)
# ---------------------------------------------------------------------
run_one_simulation <- function(scenario, N = 2000, true_tau = 2.0) {
  
  # Step 1: 基础特征生成 (多维微观劳动者画像)
  X1 <- rnorm(N, mean = 12, sd = 2.5)       # 受教育年限 (正态分布)
  X2 <- runif(N, min = 22, max = 55)        # 劳动者年龄 (均匀分布)
  X3 <- rbinom(N, 1, prob = 0.6)            # 婚姻状况 (二项分布, 1=已婚)
  alpha <- rnorm(N, mean = 0, sd = 1)       # 个体时间不变固定效应 (未观测主观动机)
  
  # Step 2: 设定处理分配机制 (D) - 劳动者为何选择参训？
  if (scenario == "A" || scenario == "B") {
    # 基准 Logit 分配模型
    prob_D <- plogis(-3.0 + 0.15 * X1 - 0.02 * X2 + 0.4 * X3)  
  } else if (scenario == "C") {
    # 随时间变化的未观测内生性混淆变量 (时变健康恶化等)
    U_0 <- rnorm(N, 0, 1)
    U_1 <- rnorm(N, 0, 1) 
    prob_D <- plogis(-3.0 + 0.15 * X1 - 0.02 * X2 + 0.4 * X3 + 0.8 * U_0)
  } else if (scenario == "D") {
    # 倾向得分模型函数形式误设 (真实的决策依赖于学历的平方项高阶非线性)
    prob_D <- plogis(-8.0 + 0.05 * (X1^2) - 0.02 * X2 + 0.4 * X3) 
  }
  D <- rbinom(N, 1, prob_D)
  
  # Step 3: 构建面板数据结构并严谨生成观测结果 Y (年收入对数)
  data <- expand_grid(id = 1:N, time = c(0, 1)) %>%
    left_join(tibble(id = 1:N, X1=X1, X2=X2, X3=X3, D=D, alpha=alpha), by = "id") %>%
    mutate(
      post = time,
      trt = D * post,
      epsilon = rnorm(2*N, mean = 0, sd = 1)
    )
  
  # 基础现实年薪决定方程
  base_Y <- function(df) { df$alpha + 0.5*df$X1 + 0.05*df$X2 + 0.3*df$X3 }
  
  if (scenario == "A") {
    # 场景 A: 满足无条件平行趋势假设
    data <- data %>% mutate(Y = base_Y(.) + (post * 3.0) + (trt * true_tau) + epsilon)
  } else if (scenario == "B") {
    # 场景 B: 异质性时间趋势 (高学历自然涨幅更快, 无条件平行趋势破裂)
    data <- data %>% mutate(Y = base_Y(.) + (post * (1.0 + 0.2 * X1)) + (trt * true_tau) + epsilon)
  } else if (scenario == "C") {
    # 场景 C: 时变未观测遗漏变量负向非对称干扰
    data <- data %>% 
      left_join(tibble(id = rep(1:N, 2), time = rep(c(0,1), each=N), U = c(U_0, U_1)), by = c("id", "time")) %>%
      mutate(Y = base_Y(.) + 1.5 * U + (post * 3.0) + (trt * true_tau) + epsilon)
  } else if (scenario == "D") {
    # 场景 D: 演进趋势受高阶非线性项驱动
    data <- data %>% mutate(Y = base_Y(.) + (post * (1.0 + 0.02 * (X1^2))) + (trt * true_tau) + epsilon)
  }
  
  # Step 4: 多方法并进多维度估计
  # 方法一：全样本不控制协变量的基础版 DID (FE固定效应模型)
  fit_did_basic <- feols(Y ~ trt | id + time, data = data, warn = FALSE, notes = FALSE)
  est_did_basic <- fit_did_basic$coeftable["trt", "Estimate"]
  
  # 方法二：全样本控制处理前协变量参数化时间趋势的回归版 DID
  fit_did_cov <- feols(Y ~ trt + X1:post + X2:post + X3:post | id + time, data = data, warn = FALSE, notes = FALSE)
  est_did_cov <- fit_did_cov$coeftable["trt", "Estimate"]
  
  # 准备进行倾向得分匹配的横截面宽数据
  data_wide <- data %>%
    pivot_wider(id_cols = c(id, X1, X2, X3, D), names_from = time, values_from = Y, names_prefix = "Y_") %>%
    mutate(delta_Y = Y_1 - Y_0)
  
  # 执行 1:1 最近邻、不放回、0.05严苛卡尺限制、丢弃非支持区域的 PSM 匹配
  psm_match <- suppressWarnings(matchit(
    D ~ X1 + X2 + X3, 
    data = data_wide, 
    method = "nearest", 
    ratio = 1, 
    replace = FALSE, 
    caliper = 0.05, 
    discard = "both"
  ))
  matched_wide <- match.data(psm_match)
  
  # 方法三：在匹配成功样本上跑变化量的一阶差分 OLS (单独 PSM 估计)
  fit_psm <- lm(delta_Y ~ D, data = matched_wide)
  est_psm <- coef(fit_psm)["D"]
  
  # 方法四：在匹配成功样本上跑双向固定效应 FE (标准的 PSM-DID)
  matched_long <- data %>% filter(id %in% matched_wide$id)
  fit_psmdid <- feols(Y ~ trt | id + time, data = matched_long, warn = FALSE, notes = FALSE)
  est_psmdid <- fit_psmdid$coeftable["trt", "Estimate"]
  
  # 打包单次实验结果
  return(tibble(
    Scenario = scenario,
    Method = c("DID_Basic", "DID_Cov", "PSM", "PSM-DID"),
    Estimate = c(est_did_basic, est_did_cov, est_psm, est_psmdid)
  ))
}

# ---------------------------------------------------------------------
# 3. 执行大样本高强度 1000 次蒙特卡洛循环模拟
# ---------------------------------------------------------------------
set.seed(20260517) # 锚定可复现伪随机种子
iterations <- 1000
scenarios <- c("A", "B", "C", "D")
true_tau <- 2.0

cat("🚀 核心全功能引擎启动！正在执行 1000次 蒙特卡洛模拟，请耐心稍候...\n")
results_df <- map_dfr(scenarios, function(scen) {
  cat("正在高精渲染并模拟场景:", scen, "...\n")
  map_dfr(1:iterations, ~run_one_simulation(scenario = scen, true_tau = true_tau))
})

# ---------------------------------------------------------------------
# 4. 结算大数定律统计指标并打印控制台
# ---------------------------------------------------------------------
summary_table <- results_df %>%
  group_by(Scenario, Method) %>%
  summarise(
    Mean_Estimate = mean(Estimate),
    Bias = mean(Estimate) - true_tau,
    RMSE = sqrt(mean((Estimate - true_tau)^2)),
    Std_Dev = sd(Estimate),
    .groups = "drop"
  ) %>%
  arrange(Scenario, Method)

cat("\n✅ [成果一展示] 1000次蒙特卡洛模拟最终收敛估计量对比表格：\n")
print(summary_table %>% mutate_if(is.numeric, round, 4))

# ---------------------------------------------------------------------
# 5. 可视化一：全新多维大样本估计量核密度分布图 (高解像 300 DPI 导出)
# ---------------------------------------------------------------------
cat("\n🎨 正在绘制成果二：多方法估计量核密度对比分布图...\n")
plot_density <- results_df %>%
  ggplot(aes(x = Estimate, fill = Method, color = Method)) +
  geom_density(alpha = 0.4, linewidth = 0.6) +
  geom_vline(xintercept = true_tau, linetype = "dashed", color = "black", linewidth = 0.8) +
  facet_wrap(~ Scenario, scales = "free", labeller = as_labeller(c(
    "A" = "Scenario A: Baseline Parallel Trends",
    "B" = "Scenario B: Heterogeneous Trends (Linear)",
    "C" = "Scenario C: Time-Varying Confounding (PIA Fails)",
    "D" = "Scenario D: PS Model Misspecification (Nonlinear)"
  ))) +
  theme_minimal(base_size = 11) + 
  labs(
    title = "Monte Carlo Simulation: Density Distributions of Causal Estimates",
    subtitle = paste0("Faceted across 4 scenarios | Dashed reference line fixed at true effect (tau = ", true_tau, ")"),
    x = "Estimated Causal Effect Value",
    y = "Empirical Probability Density"
  ) +
  scale_fill_manual(values = c("DID_Basic" = "#E41A1C", "DID_Cov" = "#984EA3", "PSM" = "#4DAF4A", "PSM-DID" = "#377EB8")) +
  scale_color_manual(values = c("DID_Basic" = "#E41A1C", "DID_Cov" = "#984EA3", "PSM" = "#4DAF4A", "PSM-DID" = "#377EB8")) +
  theme(
    legend.position = "bottom",
    panel.grid.minor = element_blank(),
    strip.text = element_text(size = 11, face = "bold", color = "#222222"),
    plot.title = element_text(size = 14, face = "bold")
  )

ggsave("density_plot.png", plot = plot_density, width = 11, height = 7, dpi = 300)
cat("✅ 成果图表一已成功安全输出至本地工作目录：'density_plot.png'\n")

# ---------------------------------------------------------------------
# 6. 可视化二：回应大作业动作要求 - 独立拉取单次平衡性检验与顶刊学术风支持图
# ---------------------------------------------------------------------
cat("\n📊 正在执行成果三考核点：独立提取单次样本生成高级平衡性支持图...\n")
set.seed(123)
N_demo <- 2000
X1_d <- rnorm(N_demo, 12, 2.5); X2_d <- runif(N_demo, 22, 55); X3_d <- rbinom(N_demo, 1, 0.6)
D_d <- rbinom(N_demo, 1, plogis(-3.0 + 0.15 * X1_d - 0.02 * X2_d + 0.4 * X3_d))
demo_wide <- tibble(D=D_d, X1=X1_d, X2=X2_d, X3=X3_d)

demo_match <- matchit(D ~ X1 + X2 + X3, data = demo_wide, method = "nearest", caliper = 0.05, discard = "both")

cat("\n[标准平衡性报告] 打印单次匹配前后的特征均衡度明细表：\n")
print(summary(demo_match)) 

# 优雅提取数据并清洗类别标签
demo_wide_results <- demo_wide %>%
  mutate(
    propensity_score = demo_match$distance,
    weights = demo_match$weights,
    discarded = demo_match$discarded,
    Status = case_when(
      D == 1 & weights > 0  ~ "Matched Treated",
      D == 1 & weights == 0 ~ "Unmatched Treated",
      D == 0 & weights > 0  ~ "Matched Control",
      D == 0 & weights == 0 ~ "Unmatched Control"
    ),
    Group = if_else(D == 1, "Treatment Group (参训组样本池)", "Control Group (对照组样本池)")
  ) %>%
  filter(!discarded) 

# 运用 ggplot2 架构设计高定莫兰迪镜像分布图
plot_common_support <- ggplot(demo_wide_results, aes(x = propensity_score, fill = Status)) +
  geom_histogram(aes(y = after_stat(density)), bins = 40, alpha = 0.65, position = "identity", color = "white", linewidth = 0.15) +
  geom_density(aes(color = Status), alpha = 0.08, linewidth = 0.5, position = "identity") +
  facet_wrap(~ Group, ncol = 1, scales = "free_y") +
  theme_minimal(base_size = 11) +
  labs(
    title = "Propensity Score Common Support Verification",
    subtitle = "Faceted distribution profiles revealing the strict overlap region (Caliper = 0.05)",
    x = "Estimated Propensity Score (预测参训概率)",
    y = "Sample Probability Density",
    fill = "Sample Assignment Status",
    color = "Sample Assignment Status"
  ) +
  scale_fill_manual(values = c("Matched Treated" = "#1F77B4", "Unmatched Treated" = "#AEC7E8", "Matched Control" = "#FF7F0E", "Unmatched Control" = "#FFBB78")) +
  scale_color_manual(values = c("Matched Treated" = "#1F77B4", "Unmatched Treated" = "#1F77B4", "Matched Control" = "#FF7F0E", "Unmatched Control" = "#FF7F0E")) +
  theme(
    panel.grid.minor = element_blank(),
    panel.grid.major.x = element_line(color = "#E5E5E5", linewidth = 0.4),
    panel.grid.major.y = element_line(color = "#F5F5F5", linewidth = 0.4),
    strip.text = element_text(size = 11, face = "bold", color = "#111111"),
    plot.title = element_text(size = 14, face = "bold", margin = margin(b = 5)),
    plot.subtitle = element_text(size = 10, color = "#555555", margin = margin(b = 10)),
    legend.position = "bottom",
    legend.background = element_rect(fill = "#FAFBAF", color = NA),
    plot.background = element_rect(fill = "white", color = NA)
  )

ggsave("common_support_plot.png", plot = plot_common_support, width = 10, height = 6.5, dpi = 300)
cat("\n✅ 成果图表二已成功输出至本地：'common_support_plot.png'\n")
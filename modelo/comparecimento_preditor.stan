// Uma única resposta: votação de Lula T2, em logit. Comparecimento é preditor.
// Índices explícitos permitem escolher qual inclinação varia, sem reordenar X.
data {
  int<lower=1> G;
  int<lower=1> P;
  int<lower=1,upper=P> K;
  array[K] int<lower=1,upper=P> varying;
  array[G] int<lower=0> n;
  array[G] matrix[P,P] xx;
  array[G] vector[P] xy;
  vector[G] yy;
  vector[P] prior_mean;
  vector<lower=0>[P] prior_sd;
  vector<lower=0>[K] prior_tau;
}
parameters {
  vector[P] beta;
  array[G] vector[K] state;
  vector<lower=0>[K] tau;
  cholesky_factor_corr[K] L;
  real<lower=0> sigma;
}
transformed parameters {
  array[G] vector[P] theta;
  for(g in 1:G) {
    theta[g] = beta;
    for(k in 1:K) theta[g][varying[k]] = state[g][k];
  }
}
model {
  beta ~ normal(prior_mean, prior_sd);
  tau ~ normal(0, prior_tau);
  L ~ lkj_corr_cholesky(2);
  sigma ~ normal(0, 1);
  for(g in 1:G) {
    state[g] ~ multi_normal_cholesky(beta[varying], diag_pre_multiply(tau,L));
    target += -n[g]*log(sigma)
      - (yy[g]-2*dot_product(theta[g],xy[g])+quad_form(xx[g],theta[g]))/(2*square(sigma));
  }
}

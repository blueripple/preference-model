data {
int<lower = 1> N; // number of districts
  int<lower = 1> M; // number of cces rows
  int<lower = 1> K; // number of predictors
  int<lower = 1, upper = N> districtE[N]; // do we need this?
  int<lower = 1, upper = M> districtC[M]; // do we need this?
  matrix[N, K] Xe;
  matrix[M, K] Xc;
  int<lower=-1, upper=1> IncE[N];
  int<lower=-1, upper=1> IncC[M];
  int<lower = 0> VAPe[N];
  int<lower = 0> VAPc[M];
  int<lower = 0> TVotesE[N];
  int<lower = 0> DVotesE[N];
  int<lower = 0> TVotesC[M];
  int<lower = 0> DVotesC[M];
}
transformed data {
int<lower=0> G = M + N;
  matrix[G, K] X = append_row (Xe, Xc);
  int<lower=-1, upper=1> Inc[G] = append_array(IncE, IncC);
  int<lower=0> VAP[G] = append_array(VAPe, VAPc);
  int<lower=0> TVotes[G] = append_array (TVotesE, TVotesC);
  int<lower=0> DVotes[G] = append_array (DVotesE, DVotesC);vector<lower=0>[K] sigma;
  matrix[G, K] X_centered;
  for (k in 1:K) {
    real col_mean = mean(X[,k]);
    X_centered[,k] = X[,k] - col_mean;
    sigma[k] = sd(Xe[,k]);
  } 
  
  matrix[G, K] Q_ast;
  matrix[K, K] R_ast;
  matrix[K, K] R_ast_inverse;
  // thin and scale the QR decomposition
  Q_ast = qr_Q(X_centered)[, 1:K] * sqrt(G - 1);
  R_ast = qr_R(X_centered)[1:K,]/sqrt(G - 1);
  R_ast_inverse = inverse(R_ast);
}
parameters {
real alphaD;
  vector[K] thetaV;
  real alphaV;
  vector[K] thetaD;
  real incBetaD;
  real <lower=1e-5, upper=(1-1e-5)> dispD;  
  real <lower=1e-5, upper=(1-1e-5)> dispV;
}
transformed parameters {
real<lower=0> phiV = dispV/(1-dispV);
  real<lower=0> phiD = dispD/(1-dispD);
  vector<lower=0, upper=1> [G] pDVoteP = inv_logit (alphaD + Q_ast * thetaD + to_vector(Inc) * incBetaD);
  vector<lower=0, upper=1> [G] pVotedP = inv_logit (alphaV + Q_ast * thetaV);
  vector [K] betaV;
  vector [K] betaD;
  betaV = R_ast_inverse * thetaV;
  betaD = R_ast_inverse * thetaD;
}
model {
alphaD ~ cauchy(0, 10);
  alphaV ~ cauchy(0, 10);
  betaV ~ cauchy(0, 2.5);
  betaD ~ cauchy(0, 2.5);
  incBetaD ~ cauchy(0, 2.5);
  phiD ~ cauchy(0,2);
  phiV ~ cauchy(0,2);
  TVotes ~ beta_binomial(VAP, pVotedP * phiV, (1 - pVotedP) * phiV);
  DVotes ~ beta_binomial(TVotes, pDVoteP * phiD, (1 - pDVoteP) * phiD);
}
generated quantities {
vector[G] log_lik;
  for (g in 1:G) {
    log_lik[g] =  beta_binomial_lpmf(DVotes[g] | TVotes[g], pDVoteP[g] * phiD, (1 - pDVoteP[g]) * phiD) ;
  }
vector<lower = 0>[G] eTVotes;
  vector<lower = 0>[G] eDVotes;
  for (g in 1:G) {
    eTVotes[g] = pVotedP[g] * VAP[g];
    eDVotes[g] = pDVoteP[g] * TVotes[g];
  }
  real avgPVoted = inv_logit (alphaV);
  real avgPDVote = inv_logit (alphaD);
  vector[K] deltaV;
  vector[K] deltaD;
  for (k in 1:K) {
    deltaV [k] = inv_logit (alphaV + sigma [k] * betaV [k]) - avgPVoted;
    deltaD [k] = inv_logit (alphaD + sigma [k] * betaD [k]) - avgPDVote;
  }
  real deltaIncD = inv_logit(alphaD + incBetaD) - avgPDVote;
}
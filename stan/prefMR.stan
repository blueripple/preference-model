data {
  int<lower = 0> G; // number of cells
  int<lower = 1> J_state; // number of states
  int<lower = 1> J_sex; // number of sex categories
  int<lower = 1> J_age; // number of age categories
  int<lower = 1> J_educ; // number of education categories
  int<lower = 1> J_race; // number of race categories  
  //  int<lower = 1, upper = J_sex> sex[G];
  //  int<lower = 1, upper = J_age> age[G];
  //  int<lower = 1, upper = J_educ> education[G];
  //  int<lower = 1, upper = J_race> race[G];
  int<lower = 1, upper = J_state> state[G];
  int<lower = 1, upper = J_age * J_sex * J_educ * J_race> category[G];
  int<lower = 0> D_votes[G];
  int<lower = 0> Total_votes[G];
}
transformed data {
  int <lower=1> nCat;
  nCat =  J_age * J_sex * J_educ * J_race;
}

parameters {
  //  real alpha;
  vector[nCat] beta;
  real<lower = 0> sigma_alpha;
  matrix[J_state, nCat] alpha;
  //  vector[J_sex] bSex;
  //  vector[J_age] bAge;
  //  vector[J_educ] bEducation;
  //  vector[J_race] bRace;
  //  real<lower = 0> sigma_theta;
  //  vector<multiplier = sigma_theta>[J_sex * J_age * J_educ * J_race * J_state] theta;
}
/*
transformed parameters {
  real alpha_p;
  alpha_p = inv_logit (alpha);
}
*/
model {
  sigma_alpha ~ normal (0, 10);
  to_vector(alpha) ~ normal (0, sigma_alpha);
  for (g in 1:G) {
    D_votes[g] ~ binomial_logit(Total_votes[g], beta[category[g]] + alpha[state[g], category[g]]);
  }
}
      
generated quantities {
  vector <lower = 0, upper = 1> [nCat] nationalProbs;
  matrix <lower = 0, upper = 1> [J_state, nCat] stateProbs;
  nationalProbs = inv_logit(beta[category]);
  for (s in 1:J_state) {
    for (c in 1:nCat) {
      stateProbs[s, c] = inv_logit(beta[c] + alpha[s, c]);
    }
  }
}
# Modeling State House Races: VA edition

It’s abundantly clear that Dems and progressives have suffered major setbacks when Republicans control
statehouses. On the voting rights front, it’s opened the door to partisan and race-based
[gerrymandering](https://www.washingtonpost.com/news/wonk/wp/2015/03/01/this-is-the-best-explanation-of-gerrymandering-you-will-ever-see/)
and
[voter suppression](https://www.aclu.org/issues/voting-rights/fighting-voter-suppression).
On hundreds of substantive issues, including
[abortion access](https://www.washingtonpost.com/politics/2021/09/01/texas-abortion-law-faq/),
[Covid-safety](https://apnews.com/article/health-government-and-politics-coronavirus-pandemic-michigan-laws-eeb73e92d5af8b46f6a1e70d8a5cbe81),
[medicaid expansion](https://apnews.com/article/wisconsin-medicaid-business-health-government-and-politics-1ab60e341674584c3059511d35ec7c21),
and [education policy](https://thehill.com/changing-america/respect/equality/558927-texas-passes-law-banning-critical-race-theory-in-schools),
Republican control is an ongoing disaster for Democratic policy positions and, more
importantly, for the people of these states. We’ve
[written before](https://blueripplepolitics.org/blog/state-races-2019)
about the importance of state-legislative
elections and, if anything, it has only become more urgent since.

VA, which holds elections for their lower house this November,
is the rare
[good-news story](https://slate.com/news-and-politics/2019/11/democrats-win-virginia-legislature.html)
in this regard:
the lower house went blue in 2019, after 20 years of Republican control,
and the state senate followed in 2020. We’d like to keep it that way.

State-legislative elections are challenging from a data
perspective: polling is almost non-existent
and detailed demographic information gets more difficult to find for smaller regions,
making any kind of forecasting difficult.
From our perspective, this makes it hard to filter
state legislative races by our number one criterion: is this a race
the Dem *can* win but also one the Dem is *not certain* to win.

We think donating efficiently to state-legislative
is extremely important, so, despite the challenges,
we attempted to estimate winnability using the available data.
Below we’ll look at our
first attempt to model expected closeness of elections in the VA lower house.
In this post we’ll feed our model 2018 data and compare the predictions to
the 2019 election outcome.
To be very clear: we’re not interested in predicting outcomes. We are interested in
determining which races are likely to be close and are thus flippable or in need of defending.

### Key Points In This Post

- Using voter-turnout and voter-preference data we can model expected
turnout and preference for a specific region.
- Demographic information for state-legislative districts (SLDs) is available from the
ACS (American Community Survey) and the decennial census. But is “some assembly required.”
- Combining this information allows us to estimate the likely outcome of an election in
a SLD.
- Our method intentionally avoids using the history of local election results.
- An exammple model, using 2018 data and comparing to 2019 results, is encouraging.

## Modeling Election Results from Demographic Information
When people use election-data and demographics to
craft new districts[^redistricting]
for congressional
or state legisltive elections, they focus almost entirely on past election results:
breaking past results down to their smallest available geographies, usually
“precincts”, further splitting those into census blocks, then reassembling
them in different ways to build new districts with predictable political leanings.

[^redistricting]: See, for example
[this](https://districtr.org) free redistricting tool. Or
[this](https://www.districtbuilder.org).  Information about all
things redistricting is available
[here](https://redistricting.lls.edu).

We don’t doubt the accuracy of these methods, especially given the financial and
computational resources given over to them during redistricting.

But what if past results are inconsistent with what we expect from a
purely demographic model?  While we expect the past-results model to
be more accurate, we also believe that mismatches between these sorts
of models are informative, perhaps highlighting the places
where the right candidate, campaign or organizing
effort can produce a surprising result, or alerting us to a district
where an incumbent Democrat might need more help defending a seat than
we might have expected.  Such districts may also point the way out
of the idea that demography is destiny, that, for example, districts
that are heavily populated by white non-college-educated voters are
impossible for Democrats to win.

For all these reasons,  we’re going to model state-legislative elections using only
demographic variables: population density,
sex (female or male are the only classifications in the data we have),
education level (non-college-grad or college-grad),
and race (Black, Latinx, Asian, white-non-Latinx, other).
We would very much like to have an age factor as well but the tables
made available by the census at the SLD level preclude this[^whyNoAge].

We assemble SLD-level demographic information using census provided
shapefiles for each district. The shapefile is used to find
all the census block-groups inside the district and those are
aggregated[^demographicCode] to construct SLD-level demographic
breakdowns of population density, sex, education and race.

Further complicating things, our favored source for turnout data, the census
bureau’s Current Population Survey Voting and Registration Supplement
([CPSVRS](https://www.census.gov/data/datasets/time-series/demo/cps/cps-supp_cps-repwgt/cps-voting.html)),
has no data about who voters chose in the election, just whether or not they
voted.  Our chosen source for voter preference information is the
the Cooperative Election Survey
([CES](https://cces.gov.harvard.edu)) which does the work of validating
survey respondents self-reported turnout with voter files[^whyCPS].  We use
each voter’s party choice for their congressional district as a proxy for
their likely vote for state legislature.

[^whyCPS]: The CES also has turnout information and it
has the advantage of being validated.  But that comes with
[it’s own issues](https://agadjanianpolitics.wordpress.com/2018/02/19/vote-validation-and-possible-underestimates-of-turnout-among-younger-americans/).
We generally run our estimations with both CPSVRS and CES as
a turnout source to make sure the results are similar but rely
on a
[slightly-corrected](https://www.aramhur.com/uploads/6/0/1/8/60187785/2013._poq_coding_cps.pdf)
version of the CPSVRS, as that seems to be the most common approach.

Our model combines those data sets at the congressional district level
and jointly estimates turnout probabilities using counts from the CPSVRS and
Dem preference from the CES. We then post-stratify the estimates across
the demographic data we built for each VA lower house district. The result is
a prediction for the expected Dem vote share in each district. More detail
about the model and data-sources can be found [here][model_description].

Cutting to the chase: in the chart below we plot the model estimate
(using 2018 data) vs. the results of the 2019 election. In blue,
we also plot the “model=result” line,
where every dot would fall if the model was somehow exact for each race.
The model is far from perfect but nonetheless
extremely informative, explaining 75% of the variance among contested races.
The uncontested races fall on the sides of the chart
and we can see that these are predictably one-sided in the model,
with the exception of district
78 (a swingy district that was uncontested by the Democrats).

[^electionModel]: See, for example,
[this description](https://hdsr.mitpress.mit.edu/pub/nw1dzd02/release/1)
of the Economist magazine’s U.S. presidenital election forecast.

[^whyNoAge]: For larger geographic areas
it’s possible to get ACS “micro-data,”
which provides specific information for many factors.
the smallest of these, Public-Use-Microdata-Areas
or “PUMA”s, contain about 100,000 people which is too big
to use to get the demographics of a SLD.
Census block-groups only contain a few thousand people, but for those
micro-data is not available.
We’re using census tables and they
do not provide 4-factor breakdowns.
So we we’re limited to sex, education and
race. Once more 2020 decennial data is available,
we may be able to improve on this.

[^demographicCode]: We built a
[python script](https://github.com/blueripple/GeoData/blob/main/code/aggregateRaw.py)
to automate most
of this process. We download shapefiles and block-group-data for the
state and the script merges those into SLD-level demogrpahics.  The
code is available on our
[github site](https://github.com/blueripple)

[^modelDetails]: We’ve written a much more detailed
description of the model
[here]()
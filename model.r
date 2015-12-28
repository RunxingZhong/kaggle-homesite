
#### libraries ####
library(readr)
library(xgboost)
library(caret)
# library(pROC)
library(tidyr)
library(dplyr)
# library(e1071)
#### functions ####
split.df <- function(df, ratio) {
  h = createDataPartition(df$QuoteConversion_Flag, p = ratio, list = FALSE, times = 1)
  list(part1 = df[h, ], part2 = df[-h, ])
}
add.date.features <- function(df, date.cols) {
  for(dc in date.cols) {
    #col = strptime(df[, dc], format='%d%b%y:%H:%M:%S', tz="UTC")
    col = as.POSIXlt(df[[dc]], origin="1970-01-01", tz = "UTC")
    tmp.df = data.frame(
      # yday = col$yday,
      mday = col$mday,
      mon = col$mon,
      year = col$year,
      wday = col$wday,
      quarters = as.numeric(gsub("Q", "", quarters(col))),
      days_since_origin = as.double(julian(col))
    )
    names(tmp.df) = paste0(dc, "_", names(tmp.df))
    # TODO: also calculate time diff using `difftime`
    #     for(dc2 in date.cols) {
    #       #col2 = strptime(df[, dc2], format='%d%b%y:%H:%M:%S', tz="UTC")
    #       col2 = as.POSIXlt(df[, dc2], origin="1970-01-01", tz = "UTC")
    #       diff.df = data.frame(day_diff = as.double(difftime(col, col2, units = "days")),
    #                            week_diff = as.double(difftime(col, col2, units = "weeks")))
    #       names(diff.df) = paste0(dc, "_timediff_", dc2, names(diff.df))
    #     }
    #     df = cbind(df, diff.df)
    df = cbind(df, tmp.df)
  }
  df
}
map.missing <- function(df, to.replace = "na", threshold = 10, impute_method = "mean") {
  names = names(df)
  names = names[!names %in% c(target_name, id_name)]
  sum(is.na(df)) / (nrow(df) * ncol(df))
  for (f in names) {
    col = df[[f]]
    value = NULL
    if (class(col) == "numeric" | class(col) == "double" | class(col) == "integer") {
      if (impute_method == "mean") {
        value = mean(col, na.rm = T)
      } else if (impute_method == "median") {
        value = median(col, na.rm = T)
      } else if(impute_method == "mostfreq") {
        value = as.numeric(names(which.max(table(col[col != to.replace]))))
      } else if(impute_method == "max+1") {
        value = max(col, na.rm = T) + 1
      } else if(impute_method == "min-1") {
        value = min(col, na.rm = T) - 1
      }
      if (length(value) > 0) {
        if (tolower(to.replace) == "na") {
          df[[f]][is.na(col)] = value
        } else if (tolower(to.replace) == "inf") {
          df[[f]][looks.like.inf(col)] = value
        } else if (to.replace == -1) {
          df[[f]][col == -1] = value
        }
      }
    }
  }
  df
}
count_per_row <- function(df, val) {
  if (is.na(val)) {
    apply(df, FUN = function(row) sum(is.na(row)), MARGIN = 1)
  } else {
    apply(df, FUN = function(row) sum(row == val, na.rm = T), MARGIN = 1)
  }
}

#### reading data ####
gc()
set.seed(88888)
cat("reading the train and test data\n")
train.full = read_csv("./input/train.csv")
test.full = read_csv("./input/test.csv")
train.backup = train.full
test.backup = test.full
id_name = "QuoteNumber"
target_name = "QuoteConversion_Flag"
id_col = train.backup[[id_name]]
target_col = train.backup[[target_name]]
id_col_test = test.backup[[id_name]]


#### initializing vars ####
for(with_missing_counts in c(0))
for(with_csbclindep in c(0))
for(with_dummyvars in c(0))
for(with_date_dummies in c(1))
for(run_cv in c(1)) {

  full_data = 1# - run_cv
  train.rows.percent = 0.9
  train_with_all = 1
  load_data = 0
  nrounds = ifelse(run_cv, 1800, 1800)
  run_train = 1 - run_cv

  exp_list = c(
    ifelse(with_dummyvars, "dummies", "no_dummies"),
    ifelse(with_date_dummies, "date_dummies", "no_date_dummies"),
    # ifelse(with_missing_counts == 1, "total_missing_count", ifelse(with_csbclindep == 2, "missing_counts", "no_missing_counts")),
    ifelse(with_csbclindep, "with_csbc_lindep", "without_csbc_lindep")
  )
  exp_suffix = paste0(collapse = "_", exp_list[exp_list != ""])
  eval_metric = "auc"
  param_bests = list(
    max_depth = 7,
    eta = 0.02,
    subsample = 0.82,
    colsample_bytree = 0.66
  )
  eval_metric_max = c("auc"=TRUE, "rmse"=FALSE, "error"=FALSE, "logloss"=FALSE)
  gc()
  set.seed(88888)
  
  neg_tab = sort(sapply(train.backup, function(col) sum(col == -1))) / nrow(train.backup)
  all_neg_cols = neg_tab[neg_tab > 0.01]
  
  # best_cv_score = 0
  # best_threshold = 0
  # thresholds_list = list()
  
#### preprocessing ####
  if (load_data & file.exists(paste0("input/train_pp_", exp_suffix, ".rds"))) {
    train.full = readRDS(paste0("input/train_pp_", exp_suffix, ".rds"))
    test.full = readRDS(paste0("input/test_pp_", exp_suffix, ".rds"))
    feature.names <- names(train.full[, -which(names(train.full) %in% c(target_name, id_name))])
  } else {
    train.full = train.backup
    test.full = test.backup
    categ = names(train.full[, sapply(train.full, is.character)])
    train.full$GeographicField63[train.full$GeographicField63 == " "] = ""
    
    train.full[is.na(train.full)]   <- 100
    test.full[is.na(test.full)]   <- 100

#       if (impute_method != "") {
#         train.full = map.missing(train.full, to.replace = -1, impute_method = impute_method)
#         test.full = map.missing(test.full, to.replace = -1, impute_method = impute_method)
#       }

    train.full = add.date.features(train.full, c("Original_Quote_Date"))
    train.full <- train.full %>% select(-Original_Quote_Date)
    
    test.full = add.date.features(test.full, c("Original_Quote_Date"))
    test.full <- test.full %>% select(-Original_Quote_Date)
    
    neg_cols = names(all_neg_cols[7:length(all_neg_cols)])
    # neg_cols = c("GeographicField61A", "GeographicField5A", "GeographicField60A", "PropertyField11A", "GeographicField21A", "GeographicField10A")
    nzv_cols = c("GeographicField10B", "PropertyField20", "PropertyField9", "PersonalField8", "PersonalField69", "PersonalField73", "PersonalField70")
    zv_cols = c("PropertyField6", "GeographicField10A")
    # linear_dep = c("PersonalField65", "PersonalField67", "PersonalField80", "PersonalField81", "PersonalField82")
    to_remove = c(neg_cols, nzv_cols, zv_cols)
    
    train.full = train.full[, !(names(train.full) %in% to_remove)]
    test.full = test.full[, !(names(test.full) %in% to_remove)]
    
    feature.names <- names(train.full[, -which(names(train.full) %in% c(target_name, id_name))])
    
    if (with_csbclindep) {
      all_data = rbind(train.full[, feature.names], test.full[, feature.names])
      pp_vals = preProcess(all_data, method = c("center", "scale", "BoxCox"))
      # save(pp_vals, file = "pp_vals") ## saving
      # load(file = "pp_vals")
      all_data_pp = predict.preProcess(pp_vals, all_data)
      train.full = all_data_pp[1:nrow(train.backup), ]
      test.full = all_data_pp[(nrow(train.backup) + 1):(nrow(train.backup) + nrow(test.backup)), ]
      train.full[[id_name]] = id_col
      train.full[[target_name]] = target_col
      test.full[[id_name]] = id_col_test
    }
    
    if (with_missing_counts == 1) {
      missing_negones = count_per_row(train.full, -1)
      missing_blank = count_per_row(train.full, "")
      missing_na = count_per_row(train.backup, NA) # note backup
      train.full$missing_all = missing_negones + missing_blank + missing_na
      
      missing_negones = count_per_row(test.full, -1)
      missing_blank = count_per_row(test.full, "")
      missing_na = count_per_row(test.backup, NA) # note backup
      test.full$missing_all = missing_negones + missing_blank + missing_na

      feature.names <- names(train.full[, -which(names(train.full) %in% c(target_name, id_name))])
    } else if (with_missing_counts == 2) {
      train.full$missing_negones = count_per_row(train.full, -1)
      train.full$missing_blank = count_per_row(train.full, "")
      train.full$missing_na = count_per_row(train.backup, NA) # note backup
      train.full$missing_negones_blank = train.full$missing_negones + train.full$missing_blank
      train.full$missing_negones_na = train.full$missing_negones + train.full$missing_na
      train.full$missing_blank_na = train.full$missing_blank + train.full$missing_na
      train.full$missing_all = train.full$missing_negones + train.full$missing_blank + train.full$missing_na
      
      test.full$missing_negones = count_per_row(test.full, -1)
      test.full$missing_blank = count_per_row(test.full, "")
      test.full$missing_na = count_per_row(test.backup, NA) # note backup
      test.full$missing_negones_blank = test.full$missing_negones + test.full$missing_blank
      test.full$missing_negones_na = test.full$missing_negones + test.full$missing_na
      test.full$missing_blank_na = test.full$missing_blank + test.full$missing_na
      test.full$missing_all = test.full$missing_negones + test.full$missing_blank + test.full$missing_na
      
      feature.names <- names(train.full[, -which(names(train.full) %in% c(target_name, id_name))])
    }
    
    if (with_dummyvars) {
      train.dummies = dummyVars( ~ ., data = train.full)
      train.full = data.frame(predict(train.dummies, newdata = train.full))
      train.full[[id_name]] = id_col
      train.full[[target_name]] = target_col
      
      test.dummies = dummyVars( ~ ., data = test.full)
      test.full = data.frame(predict(test.dummies, newdata = test.full))
      
      feature.names <- names(train.full[, -which(names(train.full) %in% c(target_name, id_name))])
    }
    
    if (with_date_dummies) {
      train.dummies = dummyVars( ~ factor(Original_Quote_Date_mon) + 
                                   factor(Original_Quote_Date_wday) +
                                   factor(Original_Quote_Date_mday) +
                                   factor(Original_Quote_Date_year) +
                                   factor(Original_Quote_Date_wday) +
                                   factor(Original_Quote_Date_quarters)
                                   , data = train.full)
      train.full = cbind(train.full, data.frame(predict(train.dummies, newdata = train.full)))
      # train.full[[id_name]] = id_col
      # train.full[[target_name]] = target_col
      
      test.dummies = dummyVars( ~ factor(Original_Quote_Date_mon) + 
                                  factor(Original_Quote_Date_wday) +
                                  factor(Original_Quote_Date_mday) +
                                  factor(Original_Quote_Date_year) +
                                  factor(Original_Quote_Date_wday) +
                                  factor(Original_Quote_Date_quarters), data = test.full)
      test.full = cbind(test.full, data.frame(predict(test.dummies, newdata = test.full)))
      
      feature.names <- names(train.full[, -which(names(train.full) %in% c(target_name, id_name))])
    }
    
    for (f in feature.names) {
      if (class(train.full[[f]])=="character") {
        levels <- unique(c(train.full[[f]], test.full[[f]]))
        train.full[[f]] <- as.integer(factor(train.full[[f]], levels=levels))
        test.full[[f]]  <- as.integer(factor(test.full[[f]],  levels=levels))
      }
    }
    
    if (with_csbclindep) {
      train_without_target = train.full[, feature.names]
      comboInfo = findLinearCombos(train_without_target)
      # save(comboInfo, file = "comboInfo") ## saving
      # load(file = "comboInfo")
      linear_dep_to_remove = comboInfo$remove
      linear_dep = names(train.full[, feature.names])[linear_dep_to_remove]
      to_remove = c(to_remove, linear_dep)
      train.full = train.full[, !(names(train.full) %in% to_remove)]
      test.full = test.full[, !(names(test.full) %in% to_remove)]
      feature.names <- names(train.full[, -which(names(train.full) %in% c(target_name, id_name))])
    }
    saveRDS(train.full, paste0("input/train_pp_", exp_suffix, ".rds"))
    saveRDS(test.full, paste0("input/test_pp_", exp_suffix, ".rds"))
    
    # cat("finished preprocessing\n")
  }
  
  
#### prepare for training ####
  
  gc()
  set.seed(9)
  
  if (full_data) {
    train.split = split.df(train.full, train.rows.percent)
    train.t = train.split$part1
    train.v = train.split$part2
    train.on.both = train.full
    train.on.v = train.v
    train.on.t = train.t
  } else {
    train.mini = split.df(train.full, 0.1)$part1
    train.mini.split = split.df(train.mini, train.rows.percent)
    train.mini.t = train.mini.split$part1
    train.mini.v = train.mini.split$part2
    train.on.both = train.mini
    train.on.v = train.mini.v
    train.on.t = train.mini.t
  }
  
#### set params ####
  param = list(   objective           = "binary:logistic", 
                  booster             = "gbtree",
                  eval_metric         = eval_metric,
                  max_depth           = param_bests$max_depth,
                  eta                 = param_bests$eta,
                  subsample           = param_bests$subsample,
                  colsample_bytree    = param_bests$colsample_bytree
                  # num_parallel_tree   = 2,
                  # alpha               = 0.0001,
                  # lambda              = 1
  )
  h = sample(nrow(train.on.both), 2000)
  dval = xgb.DMatrix(data=data.matrix(train.on.both[h, feature.names]),label=train.on.both[h, ]$QuoteConversion_Flag)
  if (train_with_all)
    dtrain = xgb.DMatrix(data=data.matrix(train.on.both[, feature.names]),label=train.on.both$QuoteConversion_Flag)
  else
    dtrain = xgb.DMatrix(data=data.matrix(train.on.t[, feature.names]),label=train.on.t$QuoteConversion_Flag)
  exp_name = paste(sep = "_", param$eval_metric, nrow(dtrain), nrounds,
                   param$max_depth, param$eta, param$subsample, param$colsample_bytree, 
                   exp_suffix)
  
  watchlist = list()
  if (nrow(dval) > 0)
    watchlist$val = dval
  watchlist$train = dtrain
  # early = round(nrounds / 10)
  
  
#### Cross Validation ####
  
  if (run_cv) {
    
    time_before_cv = Sys.time()
    nrow(dtrain)
    
    gc()
    set.seed(110389)
    
    cv.res = xgb.cv(data = dtrain,
                    objective = "binary:logistic",
                    eval_metric = "auc",
                    nrounds = nrounds,
                    nfold = 3,
                    max_depth           = param_bests$max_depth,
                    eta                 = param_bests$eta,
                    subsample           = param_bests$subsample,
                    colsample_bytree    = param_bests$colsample_bytree,
                    verbose = 1,
                    print.every.n = 10
    )
    #   save(cv.res, file = paste(exp_name, "cv", 
    #                             paste(cv.res[nrow(cv.res)]$test.auc.mean, cv.res[nrow(cv.res)]$test.auc.std, sep = "+"),
    #                             sep = "_"))
    
    #   if (best_cv_score < cv.res[nrow(cv.res)]$test.auc.mean) {
    #     best_cv_score = cv.res[nrow(cv.res)]$test.auc.mean
    #     best_threshold = neg_count
    #   }
    #   thresholds_list[[neg_count]] = cv.res
    if (F) {
      best_so_far = cv.res$test.auc.mean
      save(best_so_far, file = "best_so_far")
    }
    
    cat(exp_name, "\nCV score:", cv.res[nrow(cv.res)]$test.auc.mean, "\n")
    load(file = "best_so_far")
    compare_cv = data.frame(best = best_so_far, test = cv.res$test.auc.mean)
    plot = ggplot(compare_cv %>% gather(key, value, best, test)) + 
      geom_line(aes(x = c(seq(1, nrounds), seq(1, nrounds)), y = value, fill = key, color = key))
    # coord_cartesian(ylim = c(0.95, 0.957))
    print(plot)
    
    # cat("Time:", Sys.time() - time_before_cv, "\n")
    
  }
  # }
  
#### Train the model ####
  if (run_train) {
    time_before_training = Sys.time()
    gc()
    set.seed(110389)
    
    model = xgb.train(  params              = param, 
                        data                = dtrain, 
                        nrounds             = nrounds,
                        verbose             = 0,  #1
                        # early.stop.round    = early,
                        # watchlist           = watchlist,
                        maximize            = TRUE,
                        print.every.n       = 100
    )
    val_pred = predict(model, data.matrix(train.on.both[h, feature.names]), ntreelimit = model$bestInd)
    score = as.numeric(auc(train.on.both[h, ]$QuoteConversion_Flag, val_pred))
    cat(exp_name, "\nTraining score:", score, "\n")
    for(col in setdiff(feature.names, names(test.full))) {
      test.full[[col]] = 0
    }
    test1 <- test.full[,feature.names]
    pred1 <- predict(model, data.matrix(test1), ntreelimit = model$bestInd)
    submission <- data.frame(QuoteNumber=test.full$QuoteNumber, QuoteConversion_Flag=pred1)
    
    # cat("saving the submission file\n")
    write_csv(submission, paste0("output/", exp_name, ".csv"))
    saveRDS(train.on.t, paste0("calibration/train_", exp_name, ".rds"))
    saveRDS(train.on.v, paste0("calibration/val_", exp_name, ".rds"))
    save(feature.names, file = paste0("feature_names_", exp_name))
    xgb.save(model, paste0("models/", exp_name, ".xgb"))
    gc()
    exp_name
    
    # cat("Time: ", Sys.time() - time_before_training, "\n")
  }
}

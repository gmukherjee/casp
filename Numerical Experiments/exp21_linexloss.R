
# Experiment 2 - scenario 1

source('linexloss-agg.R')
source('spikelib.R')

require(ggplot2)
require(gridExtra)
require(Matrix)
library(foreach)
library(doParallel)

gen.spikedcov<-function(n,m.0,K,l0,tau,beta){
  
  
  #1. Generate the n x n spiked covariance matrix 
  
  set.seed(1)
  B<- matrix(rnorm(n*K,0,0.5),n,K)
  Sigma<-B%*%t(B)+l0*diag(n)
  spd<-eigen(Sigma)
  p<-spd$vectors
  temp<- diag((spd$values)^beta)
  Sigma.theta<- tau*(p%*%temp%*%t(p))
  SigmaY<- (1/m.0)*Sigma
  
  return(list("Sigma"=Sigma,"Sigma.Y"=SigmaY,
              "Sigma.theta"=Sigma.theta))
  
}
gen.data<-function(eta,m,Sigma,Sigma.theta,reps){
  
  set.seed(reps)
  theta<- mvrnorm(1,eta,Sigma.theta)
  set.seed(reps^2)
  X<- mvrnorm(m,theta,Sigma)
  return(list("theta"=theta,"X"=X))
  
}

#--- Fixed Parameters ---------------------------------  

n<- 200 # dimensionality
p<-20 # no of rows of A matrix
K.true<- 10
set.seed(1)
l0<-runif(n,0.25,1.5)#1
set.seed(1)
a<- runif(p,1,2)#linex loss parameters
b<- rep(1,p)#linex loss parameters
m<-1 # sample sizes
Mz<- seq(15,50,5)
m.0<- 1 # sample size for future data Y
reps<- 600
ineff.n<- 20
tau<-0.5
beta<-0.25
eta<-rep(0,n)
tau.grid<-c(0.1,0.25,0.5,0.75,1)
beta.grid<-c(0.1,0.25,0.5,0.75,1)

#------------- Aggregation matrix ---------------
set.seed(1)
A<- matrix(runif(p*n,0,1),p,n)
A<- A/rowSums(A)

#----Initialization ------------------------
taubeta.grid<- cbind(rep(tau.grid,each = length(beta.grid)),
                     rep(beta.grid,length(beta.grid)))

taubeta.estimated<-array(rep(0,length(Mz)*5*2),
                         c(length(Mz),5,2))


factors.estimated<-matrix(0,length(Mz),5)
shrink.f<-matrix(0,p,reps)
ineff.q<-matrix(0,ineff.n,length(Mz))
ineff.naive<-ineff.q
ineff.Bcv<-ineff.q
ineff.poet<-ineff.q
ineff.fact<-ineff.q
risk.avg<-matrix(0,ineff.n,7)

#--- Computation  ------------------------------------
for(i in 1:length(Mz)){
  
    mz<-Mz[i]
    out.Sigma<-gen.spikedcov(n,m.0,K.true,l0,tau,beta)
    sigma.Y<- sqrt(diag(A%*%out.Sigma$Sigma.Y%*%t(A)))
    
    out.rmtBayes<- rmt.est(K.true,out.Sigma$Sigma,mz,0)
    
    
    cl <- makeCluster(8)
    registerDoParallel(cl)
    
    result<-foreach(N = 1:reps,.export=c("mvrnorm","EsaBcv","POET","Factmle_cov"))%dopar%{
      
      set.seed(N)
      W<- mvrnorm(mz,rep(0,n),out.Sigma$Sigma)
      S<- cov(W)*(mz/(mz-1))
      
      K.est<- KN.test(S, mz, 0.0005)
      out.rmt<- rmt.est(K.est$numOfSpikes,S,mz,1)
     
      # Naive
      S.naive<- S.est.naive.1(S,K.est)
      
      # Bcv
      set.seed(1)
      out.Bcv<- EsaBcv(W)
      K.Bcv<- out.Bcv$best.r
      if(K.Bcv>0){
        
        S.Bcv<- cov(out.Bcv$estS)+out.Bcv$estSigma*diag(n)
        
      }
      if(K.Bcv==0){
        
        S.Bcv<- out.Bcv$estSigma*diag(n)
        
      }
      #POET
      if(i==1){
        out.poet<- POET(t(W),K.est$numOfSpikes,matrix='vad')
        S.poet<- out.poet$SigmaY
        K.poet<- dim(out.poet$factors)[1]
      }
      if(i>1){
        S.poet<- S.naive
        K.poet<-K.est$numOfSpikes
      }
      #FACTMLE
      out.fact<- Factmle_cov(S,K.est$numOfSpikes)
      S.fact<- diag(out.fact$Psi)+out.fact$Lambda%*%t(out.fact$Lambda)
      nfactors<-c(K.true, K.est$numOfSpikes,K.Bcv,K.poet,K.est$numOfSpikes)
      
      simdata<- gen.data(eta,m,out.Sigma$Sigma,out.Sigma$Sigma.theta,N)
      theta<- simdata$theta
      X<- simdata$X
      
      taubeta.q<- taubeta.q.est(taubeta.grid,out.rmt,m,X)
      taubeta.naive<- taubeta.est(taubeta.grid,S.naive,m,X)
      taubeta.Bcv<- taubeta.est(taubeta.grid,S.Bcv,m,X)
      taubeta.poet<- taubeta.est(taubeta.grid,S.poet,m,X)
      taubeta.fact<- taubeta.est(taubeta.grid,S.fact,m,X)
      
      out.q<- q.est.agg(out.rmt,A,X,a,taubeta.q[1],
                    taubeta.q[2],eta,m,m.0,0)
      qhat<-out.q$q
      f<-out.q$f
      
      qhat.1<- q.est.agg(out.rmt,A,X,a,taubeta.q[1],
                     taubeta.q[2],eta,m,m.0,1)$q
      qhat.Bayes<- q.Bayes.agg(out.Sigma$Sigma,A,X,a,tau,beta,eta,m,m.0)
      qhat.naive<- q.naive.1.agg(S.naive,A,X,a,
                             taubeta.naive[1],taubeta.naive[2],eta,m,m.0)
      qhat.Bcv<- q.Bcv.agg(S.Bcv,A,X,a,
                       taubeta.Bcv[1],taubeta.Bcv[2],eta,m,m.0)
      qhat.poet<- q.poet.agg(S.poet,A,X,a,
                         taubeta.poet[1],taubeta.poet[2],eta,m,m.0)
      qhat.fact<- q.factmle.agg(S.fact,A,X,a,
                            taubeta.fact[1],taubeta.fact[2],eta,m,m.0)
      
      risk.q<- risk.agg.est(qhat,A,theta,sigma.Y,a,b)
      risk.1<- risk.agg.est(qhat.1,A,theta,sigma.Y,a,b)
      risk.Bayes<- risk.agg.est(qhat.Bayes,A,theta,sigma.Y,a,b)
      risk.naive<- risk.agg.est(qhat.naive,A,theta,sigma.Y,a,b)
      risk.Bcv<- risk.agg.est(qhat.Bcv,A,theta,sigma.Y,a,b)
      risk.poet<- risk.agg.est(qhat.poet,A,theta,sigma.Y,a,b)
      risk.fact<- risk.agg.est(qhat.fact,A,theta,sigma.Y,a,b)
      return(list("q"=risk.q,"q.1"=risk.1,"bayes"=risk.Bayes,
                  "naive"=risk.naive,"bcv"=risk.Bcv,
                  "poet"=risk.poet,"fact"=risk.fact,"f"=f,
                  "nfactors"=nfactors,
                  "taubeta"=rbind(taubeta.q,taubeta.naive,taubeta.Bcv,
                            taubeta.poet,taubeta.fact),"out.rmt"=out.rmt))
  
    }
    stopCluster(cl)
    registerDoSEQ()
    temprisk.q<- sapply(1:reps,function(i) result[[i]]$q)
    temprisk.1<- sapply(1:reps,function(i) result[[i]]$q.1)
    temprisk.Bayes<- sapply(1:reps,function(i) result[[i]]$bayes)
    temprisk.naive<- sapply(1:reps,function(i) result[[i]]$naive)
    temprisk.Bcv<- sapply(1:reps,function(i) result[[i]]$bcv)
    temprisk.poet<- sapply(1:reps,function(i) result[[i]]$poet)
    temprisk.fact<- sapply(1:reps,function(i) result[[i]]$fact)
    
    taubeta.estimated[i,,]<- rbind(
      rowMeans(sapply(1:reps,function(i) result[[i]]$taubeta[1,])),
      rowMeans(sapply(1:reps,function(i) result[[i]]$taubeta[2,])),
      rowMeans(sapply(1:reps,function(i) result[[i]]$taubeta[3,])),
      rowMeans(sapply(1:reps,function(i) result[[i]]$taubeta[4,])),
      rowMeans(sapply(1:reps,function(i) result[[i]]$taubeta[5,])))
    
    factors.estimated[i,]<- rowMeans(sapply(1:reps,function(j) result[[j]]$nfactors))
    
    if(i == 1){
      shrink.f<- cbind(sapply(1:reps,function(j) result[[j]]$f))
    }
    
    for (kk in 1:ineff.n){
      s<- 1+30*(kk-1)
      e<- kk*30
      risk.avg[kk,]<-c(mean(temprisk.Bayes[s:e]),mean(temprisk.q[s:e]),
                       mean(temprisk.1[s:e]),mean(temprisk.naive[s:e]),
                       mean(temprisk.Bcv[s:e]),mean(temprisk.poet[s:e]),
                       mean(temprisk.fact[s:e]))
    }
    ineff.q[,i]<- (risk.avg[,2]-risk.avg[,1])/(risk.avg[,3]-risk.avg[,1])
    ineff.naive[,i]<- (risk.avg[,4]-risk.avg[,1])/(risk.avg[,3]-risk.avg[,1])
    ineff.Bcv[,i]<- (risk.avg[,5]-risk.avg[,1])/(risk.avg[,3]-risk.avg[,1])
    ineff.poet[,i]<- (risk.avg[,6]-risk.avg[,1])/(risk.avg[,3]-risk.avg[,1])
    ineff.fact[,i]<- (risk.avg[,7]-risk.avg[,1])/(risk.avg[,3]-risk.avg[,1])
    print(i)
}
save.image(paste(getwd(),'/final simulations in paper/exp21_linexloss.RData',sep=''))


ineff.mat<- c(colMeans(ineff.q[,1:8]),colMeans(ineff.naive[,1:8]),
              colMeans(ineff.Bcv[,1:8]),colMeans(ineff.fact[,1:8]))
name<- rep(c('CASPR','Naive','Bcv','FactMLE'),each=8)

shrink<- as.data.frame(rowMeans(shrink.f))
names(shrink)<- "f"
shrink$lower<- sapply(1:p,function(i) quantile(shrink.f[i,],0.10))
shrink$upper<- sapply(1:p,function(i) quantile(shrink.f[i,],0.90))
sorted.f<- order(shrink$f)
shrink$f<-shrink$f[sorted.f]
shrink$lower<-shrink$lower[sorted.f]
shrink$upper<-shrink$upper[sorted.f]
shrink$dim<- 1:p
 
plotdata1<- as.data.frame(ineff.mat)
plotdata1$name<- factor(name)
plotdata1$x<- rep(Mz[1:8],4)
plotdata2<- as.data.frame(rep(1,8))
plotdata2$x<- Mz[1:8]
names(plotdata2)<- c("Y","x")
g1<-ggplot()+geom_line(data=plotdata2,aes(x = x, y = Y))+
  geom_line(data=plotdata1, aes(x = x, y = ineff.mat,color=name))+
  geom_point(data=plotdata1,aes(x = x, y = ineff.mat,color=name,
                                shape=name))+
  scale_x_continuous(breaks = Mz[1:8])+
  scale_y_continuous(breaks = seq(0.9,2.1,by=0.1))+
  xlab(expression(m))+ylab("REE")+theme_bw()+
  theme(legend.position=c(0.5,0.85),legend.title=element_blank(),
        legend.background = element_rect(fill="white",
                                         size=1, linetype="solid", colour ="black"),
        legend.text=element_text(size=12),
        axis.text.x = element_text(size=15),
        axis.text.y = element_text(size=15),
        axis.title.x = element_text(size=15),
        axis.title.y = element_text(size=15))
  
g2<- ggplot()+geom_point(data=shrink,aes(x=dim,y=f),color="red")+
  geom_line(data=shrink,aes(x=dim,y=f),color="red")+
  geom_ribbon(data=shrink,aes(x=dim,ymin=lower,ymax=upper),alpha=0.5,fill="gray")+
  scale_x_continuous(breaks = 1:p)+
  ylab("Shrinkage factors")+xlab("Dimensions")+
  theme_bw()+
  theme(axis.text.x = element_text(size=15),
        axis.text.y = element_text(size=15),
        axis.title.x = element_text(size=15),
        axis.title.y = element_text(size=15))

grid.arrange(g1,g2,ncol=2)



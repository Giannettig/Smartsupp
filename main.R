#Install the libraries
library(httr)
library(data.table)
library(dplyr)
library(xml2)
library(jsonlite)
library(purrr)
library(readr)
library(doParallel)

#=======BASIC INFO ABOUT THE SmartSupp EXTRACTOR========#


#=======CONFIGURATION========#
## initialize application
library('keboola.r.docker.application')
app <- DockerApplication$new('/data/')

app$readConfig()

## access the supplied value of 'myParameter'
apiKey<-app$getParameters()$`#apiKey`

##Catch config errors

if(is.null(apiKey)) stop("enter your apiKey in the user config field")

## Retrieve conversation 

#get the account_id

aid<-GET("https://api.smartsupp.com/accounts",add_headers("apiKey"=apiKey))%>%
  content("text",encoding = "UTF-8")%>%fromJSON(flatten=TRUE,simplifyDataFrame = TRUE)%>%
  map_chr("id")



# Get Converstationv list ------------------------------------------------------


#This function loops through all conversations and retrieve their summary

get_conversation_list<-function(aid,apiKey,limit=200){
  
  #create the endpoint
  endpoint<-paste0("https://api.smartsupp.com/accounts/",aid,"/conversations/search")
  
  #get the size of the list
  size<-POST(endpoint,body = list(offset = 1, limit= 1),add_headers("apiKey"=apiKey))%>%
    content("text",encoding = "UTF-8")%>%fromJSON(flatten=TRUE,simplifyDataFrame = TRUE)%>%
    .$total
  
  
  registerDoParallel(cores=detectCores()-1)
  
  data<-foreach(i=seq(0,size,by = limit), .combine=bind_rows,.multicombine = TRUE, .init=NULL) %dopar% {
    r <- RETRY(
      verb="POST",
      url=endpoint,
      config=add_headers("apiKey"=apiKey),
      times = 2,
      body = list(offset = i, limit= limit),
      encode = "json"
    )
    
    res<-content(r,"text",encoding = "UTF-8")%>%fromJSON(flatten=TRUE,simplifyDataFrame = TRUE)%>%.$items
    
    res}%>%distinct
  
  data
  
}


# Get single conversation -------------------------------------------------


#define the combine function this function at the end of the parallell cycle glues togheter the result chunks
combine<-function(...){
  data<-list(...)
  a<-map(names(data[[1]]),function(x){rbindlist(map(data,x),fill=TRUE) })
  names(a)<-names(data[[1]])    
  a
}

#This function takes returns a single conversation as a list of dataframes

get_conversations<-function(cids,aid,apiKey){
  
  #use do parallel package do loop through the api and generate a list of dataframes
  
  registerDoParallel(cores=detectCores()-1)
  
  data<-foreach(i=cids,.combine=combine,.multicombine = TRUE, .errorhandling="remove") %dopar% {
    
    endpoint<-paste0("https://api.smartsupp.com/accounts/",aid,"/conversations/",i,"/get")
    
    r <-RETRY("GET",url=endpoint,config=add_headers("apiKey"=apiKey))
    
    apires<-content(r,"text",encoding = "UTF-8")%>%fromJSON(flatten=TRUE)
  
    if(r$status_code != 200) stop(paste0("Error calling cid: ",cid,", HTTP status ",r$status_code," API response: ", apires$error))
    
    paths<-mutate(apires$paths,conversation_id=i,num=row_number())
    
    messages<-mutate(apires$messages,conversation_id=i,num=row_number())
    
    visitors<-mutate(as_data_frame(t(unlist(apires$visitor))),conversation_id=i) 
    
    res<-list(paths=paths,messages=messages,visitors=visitors)
  }
  
}


# Write converstations ----------------------------------------------------

###this functions loops through the ids and retrieves messages, paths, and visitors and writes them directly to the file so I do not run out of memory
#I do this in chunkd by 200 since it seems there is a stop limit on the api

write_conversations<-function(ids,aid,apiKey,chunk_size=200){
  
  div<-seq(chunk_size,length(ids),chunk_size)
  
  walk(seq(1:length(div)), function(i){ 
    res<-get_conversations(ids[seq(chunk_size*(i-1)+1,chunk_size*(i))],aid,apiKey) 
    
    fwrite(res$paths,"out/tables/paths.csv", append=TRUE)
    fwrite(res$messages,"out/tables/messages.csv", append=TRUE)
    fwrite(res$visitors,"out/tables/visitors.csv", append=TRUE)
    
  } )
  
}


# Iteration over API ------------------------------------------------------


#Process the conversations get their ids and remove them from memory

write('Fetching all conversations', stdout())

system.time(conversations<-get_conversation_list(aid,apiKey))

write('Export out/tables/conversations.csv', stdout())

write_csv(conversations,"out/tables/conversations.csv")

ids<-conversations$id

rm(conversations)

#write('Getting individual messages, parallelized version', stdout())

system.time(write_conversations(ids,aid,apiKey,chunk_size=400)) 

write('Done', stdout())


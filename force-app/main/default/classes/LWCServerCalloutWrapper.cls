public with sharing class LWCServerCalloutWrapper {
    @AuraEnabled public Boolean isSuccess { get; set; }
    @AuraEnabled public String errorMsg { get; set; }
    @AuraEnabled public Object result { get; set; }
    @AuraEnabled public List<Object> resultList { get; set; }
    @AuraEnabled public Map<String, Object> referenceCache { get; set; }

    public LWCServerCalloutWrapper() {
        this.isSuccess = false;
        this.errorMsg = '';
        this.referenceCache = new Map<String, Object>();
    }
}
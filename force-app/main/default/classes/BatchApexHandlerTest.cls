@isTest
public class BatchApexHandlerTest {

    public static Integer executeCount = 0;
    public static Integer failThroughAttempt = 0;
    public static Boolean finishCalled = false;
    public static Boolean lastHadErrors = false;
    public static Integer recordsProcessed = 0;

    static User createStandardUser() {
        List<Profile> profiles = [
            SELECT Id, Name FROM Profile
            WHERE UserLicense.Name = 'Salesforce' AND PermissionsModifyAllData = false
            AND PermissionsViewAllData = false AND PermissionsCustomizeApplication = false
            ORDER BY Name
        ];
        Profile chosen = profiles[0];
        for (Profile candidate : profiles) {
            if (candidate.Name == 'Standard User' || candidate.Name == 'Usuario estándar') { chosen = candidate; break; }
        }
        String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
        User user = new User(
            ProfileId = chosen.Id, FirstName = 'Standard', LastName = 'Tester', Alias = 'stdtst',
            Email = 'standard.tester@example.com', Username = 'standard.tester.' + unique + '@example.com',
            TimeZoneSidKey = 'America/Montevideo', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        insert user;
        return user;
    }

    @isTest
    static void testDefaultsWhenNoConfigExists() {
        insert new Opportunity(Name = 'Batch Handler Test 1', StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        BatchApexHandlerTestBatch batch = new BatchApexHandlerTestBatch();

        Test.startTest();
        Id jobId = BatchApexHandler.run(batch);
        Test.stopTest();

        Assert.isNotNull(jobId, 'a class with no configuration record still runs');
        Assert.areEqual(1, executeCount, 'executeScope ran once for the one queried Opportunity');
        Assert.isTrue(finishCalled, 'onFinish ran');
        Assert.isFalse(lastHadErrors, 'no errors were simulated');
    }

    @isTest
    static void testInactiveConfigSkipsEnqueue() {
        BatchApexHandlerTestBatch batch = new BatchApexHandlerTestBatch();
        batch.configureForTest(false, 0, false, null, null);

        Id jobId = BatchApexHandler.run(batch);

        Assert.isNull(jobId, 'an inactive class does not get enqueued');
        Assert.areEqual(0, executeCount, 'a skipped job never reaches executeScope');
    }

    @isTest
    static void testExecuteScopeFailureIsLoggedAndRethrown() {
        insert new Opportunity(Name = 'Batch Handler Test 2', StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        failThroughAttempt = 1;
        BatchApexHandlerTestBatch batch = new BatchApexHandlerTestBatch();

        Test.startTest();
        BatchApexHandler.run(batch);
        try {
            Test.stopTest();
        } catch (DmlException ex) {
            System.debug(ex.getMessage());
        }

        Assert.areEqual(1, executeCount, 'executeScope ran once and threw');
        Assert.isFalse(finishCalled, 'test context never reaches finish() when the only chunk throws');
    }

    @isTest
    static void testDefaultMaxRetryIsZeroSoFailureIsImmediate() {
        BatchApexHandlerTestBatch batch = new BatchApexHandlerTestBatch();

        batch.invokeHandleFinishForTest(1);

        Assert.isTrue(finishCalled, 'onFinish ran');
        Assert.isTrue(lastHadErrors, 'the reported error count surfaces as an error');
    }

    @isTest
    static void testRetrySucceedsOnSecondAttempt() {
        insert new Opportunity(Name = 'Batch Handler Test 3', StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        BatchApexHandlerTestBatch batch = new BatchApexHandlerTestBatch();
        batch.configureForTest(true, 2, false, null, null);

        Test.startTest();
        batch.invokeHandleFinishForTest(1);
        Test.stopTest();

        Assert.areEqual(1, executeCount, 'the re-enqueued retry actually runs and processes the record');
        Assert.isTrue(finishCalled, 'onFinish ran once the retry completed');
        Assert.isFalse(lastHadErrors, 'the retry attempt had no errors');
    }

    @isTest
    static void testRetryExhaustedSendsFailureEmailToMultipleRecipients() {
        BatchApexHandlerTestBatch batch = new BatchApexHandlerTestBatch();
        batch.configureForTest(true, 1, true, 'first@example.com; second@example.com', null);
        batch.setRetryAttemptForTest(1);
        Integer emailsBefore = Limits.getEmailInvocations();

        batch.invokeHandleFinishForTest(1);

        Assert.isTrue(finishCalled, 'onFinish ran once retries were exhausted');
        Assert.isTrue(lastHadErrors, 'the completing attempt still had errors');
        Assert.areEqual(emailsBefore + 1, Limits.getEmailInvocations(), 'the configured failure email is sent exactly once');
    }

    @isTest
    static void testAFullChunkOfRecordsIsProcessed() {
        List<Opportunity> opportunities = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opportunities.add(new Opportunity(Name = 'Batch Handler Bulk ' + i, StageName = 'Prospecting', CloseDate = Date.today().addDays(30)));
        }
        insert opportunities;

        Test.startTest();
        BatchApexHandler.run(new BatchApexHandlerTestBatch());
        Test.stopTest();

        Assert.areEqual(200, recordsProcessed, 'every record reached executeScope');
        Assert.isTrue(finishCalled && !lastHadErrors, 'and the job finished without errors');
    }

    @isTest
    static void testRetryCanBeDelayed() {
        BatchApexHandlerTestBatch batch = new BatchApexHandlerTestBatch();
        batch.configureForTest(true, 1, false, null, null);
        batch.setRetryDelayForTest(5);

        Test.startTest();
        batch.invokeHandleFinishForTest(1);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'BatchApexHandlerTestBatch retry 1%'], 'the retry is scheduled instead of started right away');
        Assert.isFalse(finishCalled, 'onFinish waits for the retry');
    }

    @isTest
    static void testStandardUserCanRunBatches() {
        insert new Opportunity(Name = 'Batch Handler Standard User', StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        User standardUser = createStandardUser();
        Id jobId;
        System.runAs(standardUser) {
            Test.startTest();
            jobId = BatchApexHandler.run(new BatchApexHandlerTestBatch());
            Test.stopTest();
        }

        Assert.isNotNull(jobId, 'a non-admin user can start a batch: reading the configuration needs no permission');
        Assert.isTrue(finishCalled, 'and it runs to the end');
    }
}

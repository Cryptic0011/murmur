import Testing
@testable import Murmur

@Suite("LocalCleanup")
struct LocalCleanupTests {
    @Test("removes fillers and spoken punctuation in prose")
    func proseCleanup() {
        let cleaned = LocalCleanup.clean("um hello there question mark", mode: .prose)
        #expect(cleaned == "Hello there?")
    }

    @Test("explicit correction markers cut preceding text")
    func correctionMarkerCuts() {
        let cleaned = LocalCleanup.clean("send it tomorrow scratch that send it friday", mode: .prose)
        #expect(cleaned == "Send it friday.")
    }

    @Test("bare 'i mean' mid-sentence does not delete preceding text")
    func iMeanIsNotACorrectionMarker() {
        let cleaned = LocalCleanup.clean("the deploy failed i mean the staging deploy failed", mode: .prose)
        #expect(cleaned.contains("deploy failed i mean the staging") || cleaned.lowercased().hasPrefix("the deploy failed"))
    }

    @Test("normalizes email and percentages")
    func commonPatterns() {
        let cleaned = LocalCleanup.clean("send it to jane at example dot com it is fifty percent done", mode: .light)
        #expect(cleaned.contains("jane@example.com"))
        #expect(cleaned.contains("50%"))
    }

    @Test("email mode formats explicit greetings with a blank line")
    func emailExplicitGreeting() {
        let cleaned = LocalCleanup.clean("hi jordan can you send the updated proposal", mode: .email)
        #expect(cleaned == "Hi Jordan,\n\nCan you send the updated proposal.")
    }

    @Test("email mode formats direct address with a blank line")
    func emailDirectAddress() {
        let cleaned = LocalCleanup.clean("jordan comma please send the updated proposal", mode: .email)
        #expect(cleaned == "Hi Jordan,\n\nPlease send the updated proposal.")
    }

    @Test("notes mode formats dictated markdown structure")
    func notesMarkdownStructure() {
        let cleaned = LocalCleanup.clean(
            "title project plan new line heading next steps new line bullet point confirm scope new line checkbox send recap",
            mode: .notes
        )
        #expect(cleaned == """
        # Project plan
        ## Next steps
        - Confirm scope.
        - [ ] Send recap.
        """)
    }

    @Test("keeps code mode conservative but maps symbols")
    func codeCleanup() {
        let cleaned = LocalCleanup.clean("open paren foo underscore bar close paren dash dash help", mode: .code)
        #expect(cleaned.contains("( foo_bar )") || cleaned.contains("(foo_bar)"))
        #expect(cleaned.contains("-- help") || cleaned.contains("--help"))
    }

    @Test("correction markers need word boundaries and only drop the corrected clause")
    func correctionMarkerBoundaries() {
        #expect(LocalCleanup.clean("there is no waiting list for the piano lessons", mode: .prose)
                == "There is no waiting list for the piano lessons.")
        #expect(LocalCleanup.clean("I'd go for rather simple designs here", mode: .prose)
                == "I'd go for rather simple designs here.")
        #expect(LocalCleanup.clean("never mind the cost, we should ship", mode: .prose)
                == "Never mind the cost, we should ship.")
        #expect(LocalCleanup.clean("Ship it today. Send it tomorrow, no wait, send it friday", mode: .prose)
                == "Ship it today. Send it friday.")
        #expect(LocalCleanup.clean("is it ready scratch that are we ready?", mode: .prose) == "Are we ready?")
        #expect(LocalCleanup.clean("There was no wait at the DMV today.", mode: .prose) == "There was no wait at the DMV today.")
        #expect(LocalCleanup.clean("No wait time at the clinic.", mode: .prose) == "No wait time at the clinic.")
        #expect(LocalCleanup.clean("We got in with no wait. The food was great", mode: .prose)
                == "We got in with no wait. The food was great.")
    }

    @Test("a correction that opens a sentence replaces the sentence before it")
    func sentenceOpeningCorrection() {
        #expect(LocalCleanup.clean("Send it to John. No wait, send it to Mary.", mode: .chat) == "Send it to Mary.")
        #expect(LocalCleanup.clean("Is it Monday? Scratch that, is it Tuesday?", mode: .prose) == "Is it Tuesday?")
        #expect(LocalCleanup.clean("Hi team. Send it to John. Oh wait, send it to Mary.", mode: .prose) == "Hi team. Send it to Mary.")
        #expect(LocalCleanup.clean("Ship it today. Send it tomorrow. Scratch that.", mode: .prose) == "Ship it today.")
        #expect(LocalCleanup.clean("The price is 9.99. No wait, it is 10.99.", mode: .prose) == "It is 10.99.")
        // A title isn't a sentence end.
        #expect(LocalCleanup.clean("Ask Dr. Patel. No wait, ask Dr. Kim.", mode: .chat) == "Ask Dr. Kim.")
        #expect(LocalCleanup.clean("Send it to Mr. Smith. No wait, send it to Mrs. Jones.", mode: .chat) == "Send it to Mrs. Jones.")
        #expect(LocalCleanup.clean("Call Dr. Patel, no wait, call Dr. Kim.", mode: .chat) == "Call Dr. Kim.")
        // Chained corrections each retract the one before.
        #expect(LocalCleanup.clean("Ship it Monday. No wait, Tuesday. No wait, Wednesday.", mode: .chat) == "Wednesday.")
        #expect(LocalCleanup.clean("A. B. No wait, C. No wait, D.", mode: .prose) == "A. D.")
        // Stacked markers are one correction and leave the sentence before them alone.
        #expect(LocalCleanup.clean("Ship it today. Send it tomorrow, no wait, scratch that, send it friday", mode: .prose)
                == "Ship it today. Send it friday.")
        #expect(LocalCleanup.clean("Hi team. Send it to John. Oh wait, scratch that, send it to Mary.", mode: .prose)
                == "Hi team. Send it to Mary.")
        #expect(LocalCleanup.clean("Thanks for the update. Order the blue one, oh wait, scratch that.", mode: .prose)
                == "Thanks for the update.")
        #expect(LocalCleanup.clean("Sure, I can do Friday, wait no, scratch that.", mode: .prose)
                == "Sure, I can do Friday, wait no, scratch that.")
        // "p.m."/"U.S." before a lowercase word is mid-sentence; a lowercase brand name still opens one.
        #expect(LocalCleanup.clean("Let's meet at 3 p.m. tomorrow, no wait, scratch that, 4 p.m.", mode: .prose) == "4 p.m.")
        #expect(LocalCleanup.clean("We're shipping to the U.S. next week, no wait, to Canada.", mode: .prose) == "To Canada.")
        #expect(LocalCleanup.clean("Thanks for the heads up. iPhone orders ship Monday, no wait, Tuesday.", mode: .prose)
                == "Thanks for the heads up. Tuesday.")
    }

    @Test("expanding case mappings never trap")
    func expandingCaseMappings() {
        #expect(LocalCleanup.clean("İİİİİİ scratch that", mode: .prose) == "İİİİİİ scratch that.")
        #expect(LocalCleanup.clean("İstanbul trip, never mind", mode: .prose) == "İstanbul trip, never mind.")
        #expect(LocalCleanup.clean("İstanbul trip is great scratch that we go to Ankara", mode: .prose) == "We go to Ankara.")
    }

    @Test("spoken punctuation words that are ordinary words stay words")
    func spokenTokenFalsePositives() {
        #expect(LocalCleanup.clean("the trial period ends friday", mode: .prose) == "The trial period ends friday.")
        #expect(LocalCleanup.clean("we extended the trial period", mode: .prose) == "We extended the trial period.")
        #expect(LocalCleanup.clean("i'll be there period", mode: .prose) == "I'll be there.")
        #expect(LocalCleanup.clean("colon cancer screening", mode: .prose) == "Colon cancer screening.")
        #expect(LocalCleanup.clean("we launched a new line of products", mode: .chat) == "We launched a new line of products.")
        #expect(LocalCleanup.clean("she wore a polka dot dress", mode: .prose) == "She wore a polka dot dress.")
        #expect(LocalCleanup.clean("draw a dot on the map", mode: .prose) == "Draw a dot on the map.")
        #expect(LocalCleanup.clean("it was a six month period we grew", mode: .prose) == "It was a 6 month period we grew.")
        #expect(LocalCleanup.clean("during the enrollment period we will email everyone", mode: .chat)
                == "During the enrollment period we will email everyone.")
        #expect(LocalCleanup.clean("we scored twice in the third period and won", mode: .chat)
                == "We scored twice in the third period and won.")
        #expect(LocalCleanup.clean("Over the same period, revenue doubled.", mode: .prose) == "Over the same period, revenue doubled.")
        #expect(LocalCleanup.clean("That was a tough period.", mode: .prose) == "That was a tough period.")
    }

    @Test("spoken period and colon convert mid-dictation too")
    func midTextPunctuation() {
        #expect(LocalCleanup.clean("i'll be there at noon period talk soon", mode: .chat).hasPrefix("I'll be there at noon. "))
        #expect(LocalCleanup.clean("have a great day period", mode: .chat) == "Have a great day.")
        #expect(LocalCleanup.clean("see you next week period", mode: .chat) == "See you next week.")
        #expect(LocalCleanup.clean("we will ship it next year period new paragraph thanks", mode: .chat)
                == "We will ship it next year.\n\nThanks.")
        #expect(LocalCleanup.clean("agenda colon budget timeline hiring", mode: .chat) == "Agenda: budget timeline hiring.")
    }

    @Test("new line works outside notes and email")
    func newLineEverywhere() {
        #expect(LocalCleanup.clean("first line new line second line", mode: .chat) == "First line\nSecond line.")
        #expect(LocalCleanup.clean("agenda colon new line first item", mode: .notes) == "Agenda:\nFirst item.")
    }

    @Test("domains, file names, decimals, and times survive")
    func literalsSurvive() {
        #expect(LocalCleanup.clean("check out github.com for the docs", mode: .prose) == "Check out github.com for the docs.")
        #expect(LocalCleanup.clean("edit the readme.md file", mode: .prose) == "Edit the readme.md file.")
        #expect(LocalCleanup.clean("go to example dot com", mode: .prose) == "Go to example.com.")
        #expect(LocalCleanup.clean("we use Node.js and README.md e.g. for docs", mode: .prose)
                == "We use Node.js and README.md e.g. for docs.")
        #expect(LocalCleanup.clean("pi is 3.14 and the meeting is at 10:30", mode: .prose)
                == "Pi is 3.14 and the meeting is at 10:30.")
        #expect(LocalCleanup.clean("john at mail dot example dot com", mode: .prose) == "john@mail.example.com.")
        #expect(LocalCleanup.clean("check the docs at apple dot com", mode: .prose) == "Check the docs at apple.com.")
        #expect(LocalCleanup.clean("email john dot smith at gmail dot com", mode: .prose) == "Email john.smith@gmail.com.")
        #expect(LocalCleanup.clean("sign in at example dot com", mode: .prose) == "Sign in at example.com.")
        #expect(LocalCleanup.clean("log in at portal dot acme dot com", mode: .prose) == "Log in at portal.acme.com.")
        #expect(LocalCleanup.clean("it's available at amazon dot com", mode: .prose) == "It's available at amazon.com.")
        #expect(LocalCleanup.clean("jane at example dot com", mode: .prose) == "jane@example.com.")
        // Only a spoken address joins; "at 9.99" or "at github.com" is already literal.
        #expect(LocalCleanup.clean("Prices start at 9.99", mode: .prose) == "Prices start at 9.99.")
        #expect(LocalCleanup.clean("Read more at github.com", mode: .prose) == "Read more at github.com.")
        #expect(LocalCleanup.clean("so do i", mode: .prose) == "So do I.")
    }

    @Test("email greetings only come from greetings or comma-set names")
    func emailGreetingHeuristics() {
        #expect(LocalCleanup.clean("Tomorrow we will ship the update", mode: .email) == "Tomorrow we will ship the update.")
        #expect(LocalCleanup.clean("Sorry I missed your call earlier", mode: .email) == "Sorry I missed your call earlier.")
        #expect(LocalCleanup.clean("Hey I wanted to ask about the invoice", mode: .email)
                == "Hey I wanted to ask about the invoice.")
        #expect(LocalCleanup.clean("Dear Professor Jones, I hope you are well", mode: .email)
                == "Dear Professor Jones,\n\nI hope you are well.")
        #expect(LocalCleanup.clean("hello McDonald, can you send it", mode: .email) == "Hello McDonald,\n\nCan you send it.")
        #expect(LocalCleanup.clean("hi jordan new paragraph can you send it", mode: .email) == "Hi Jordan,\n\nCan you send it.")
        #expect(LocalCleanup.clean("however, i think we should wait until monday", mode: .email)
                == "However, I think we should wait until monday.")
        #expect(LocalCleanup.clean("first, we need to finalize the budget", mode: .email) == "First, we need to finalize the budget.")
    }

    @Test("notes keywords in an ordinary sentence aren't structure")
    func notesFalsePositives() {
        #expect(LocalCleanup.clean("Checked the logs and found nothing", mode: .notes) == "Checked the logs and found nothing.")
        #expect(LocalCleanup.clean("Title insurance is due Friday", mode: .notes) == "Title insurance is due Friday.")
        #expect(LocalCleanup.clean("heading north tomorrow", mode: .notes) == "Heading north tomorrow.")
        #expect(LocalCleanup.clean("todo: buy milk", mode: .notes) == "- [ ] Buy milk.")
    }

    @Test("code mode keeps shell arguments apart")
    func codeCommands() {
        #expect(LocalCleanup.clean("cd slash usr slash local", mode: .code) == "cd /usr/local")
        #expect(LocalCleanup.clean("git commit dash dash amend", mode: .code) == "git commit --amend")
        #expect(LocalCleanup.clean("cd dot dot slash src", mode: .code) == "cd ../src")
        #expect(LocalCleanup.clean("ls dash la slash tmp", mode: .code) == "ls -la /tmp")
        #expect(LocalCleanup.clean("git add dot", mode: .code) == "git add .")
        #expect(LocalCleanup.clean("self dot view dot frame", mode: .code) == "self.view.frame")
    }

    @Test("removing fillers leaves no stray commas")
    func fillerCommas() {
        #expect(LocalCleanup.clean("Um, I think we should go.", mode: .prose) == "I think we should go.")
        #expect(LocalCleanup.clean("So, um, I think we should go.", mode: .prose) == "So, I think we should go.")
        #expect(LocalCleanup.clean("uh huh that works", mode: .prose) == "That works.")
    }

    @Test("compound numbers convert whole")
    func numbers() {
        #expect(LocalCleanup.clean("about twenty five percent of users", mode: .prose) == "About 25% of users.")
        #expect(LocalCleanup.clean("we grew two hundred percent", mode: .prose) == "We grew 200%.")
        #expect(LocalCleanup.clean("one day we'll go", mode: .prose) == "One day we'll go.")
        #expect(LocalCleanup.clean("it takes five minutes and a hundred percent effort", mode: .prose)
                == "It takes 5 minutes and 100% effort.")
    }

    @Test("paragraph ends get a period, single line breaks don't")
    func paragraphPunctuation() {
        #expect(LocalCleanup.clean("hello world new paragraph second paragraph here", mode: .prose)
                == "Hello world.\n\nSecond paragraph here.")
    }
}
